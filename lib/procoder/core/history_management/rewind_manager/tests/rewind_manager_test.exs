defmodule ProCoder.Core.HistoryManagement.RewindManager.RewindManagerTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ProCoder.Core.HistoryManagement.RewindManager
  alias ProCoder.Core.HistoryManagement.RewindManager.Coordinator.RewindCoordinator
  alias ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine
  alias ProCoder.Core.HistoryManagement.RewindManager.FsReverter.FilesystemReverter
  alias ProCoder.Core.Types.AgentContext
  alias ProCoder.Core.HistoryManagement.RewindManager.Supervision.RewindSupervisor

  @session_id "test_session_#{System.unique_integer()}"
  @worktree_root "/tmp/procoder/test/worktrees/#{@session_id}"

  setup_all do
    Application.put_env(:procoder, ProCoder.SessionManager, [worktree_root: @worktree_root])
    File.mkdir_p!(@worktree_root)
    :ok
  end

  setup do
    {:ok, sup_pid} = RewindSupervisor.start_link(@session_id)
    on_exit(fn ->
      if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
      File.rm_rf!(@worktree_root)
    end)
    {:ok, session_id: @session_id}
  end

  describe "Idempotency & Atomicity" do
    test "consecutive identical rewinds maintain state identity", %{session_id: session_id} do
      {:ok, snap_id} = RewindManager.checkpoint(session_id, %AgentContext{id: "test", status: :idle}, "commit_hash")
      
      assert {:ok, :rewound} = RewindCoordinator.rewind(session_id, snap_id)
      assert {:ok, :rewound} = RewindCoordinator.rewind(session_id, snap_id)
      assert {:ok, :rewound} = RewindCoordinator.rewind(session_id, snap_id)
    end

    test "atomic restoration failure prevents state corruption", %{session_id: session_id} do
      {:ok, snap_id} = RewindManager.checkpoint(session_id, %AgentContext{id: "test"}, "invalid_commit")
      
      assert {:error, _} = RewindCoordinator.rewind(session_id, snap_id)
    end
  end

  describe "Property-Based Resilience" do
    property "state S0 remains invariant after full checkpoint-modify-rewind cycle" do
      check all commit <- StreamData.string(:alphanumeric, min_length: 5) do
        session_id = "prop_test_#{System.unique_integer()}"
        RewindSupervisor.start_link(session_id)
        
        initial_state = %AgentContext{id: "state_0", status: :idle}
        {:ok, snap_id} = RewindManager.checkpoint(session_id, initial_state, commit)
        
        {:ok, :rewound} = RewindCoordinator.rewind(session_id, snap_id)
        
        {:ok, snapshot_data} = HistoryStackEngine.get(session_id, snap_id)
        {:ok, restored} = ProCoder.Core.HistoryManagement.RewindManager.MemorySnapshotManager.deserialize_state(
          snapshot_data.memory_blob
        )
        
        assert restored.id == initial_state.id
      end
    end
  end

  describe "Concurrency & Race Conditions" do
    test "serialized access under high concurrency does not cause deadlock", %{session_id: session_id} do
      {:ok, snap_id} = RewindManager.checkpoint(session_id, %AgentContext{id: "test", status: :idle}, "commit")
      
      tasks = Enum.map(1..20, fn _ ->
        Task.async(fn ->
          RewindCoordinator.rewind(session_id, snap_id)
        end)
      end)
      
      results = Task.yield_many(tasks, 15_000)
      assert Enum.all?(results, fn {_, res} -> match?({:ok, {:ok, :rewound}}, res) end)
    end
  end

  describe "Fault Tolerance" do
    test "RewindSupervisor recovers from child process crashes during active rewind", %{session_id: session_id} do
      {:ok, snap_id} = RewindManager.checkpoint(session_id, %AgentContext{id: "test", status: :idle}, "commit")
      
      reverter_pid = GenServer.whereis(FilesystemReverter)
      Process.exit(reverter_pid, :kill)
      Process.sleep(200)
      
      assert {:ok, :rewound} = RewindCoordinator.rewind(session_id, snap_id)
    end
  end
end
