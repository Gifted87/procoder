defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.Tests.SessionManagerIntegrationTest do
  @moduledoc """
  Integration test suite for the ProCoder.Core.OrchestrationLayer.SessionManager.
  Validates concurrent spawning, worktree isolation, lifecycle events, and fault-tolerant recovery.
  """

  use ExUnit.Case, async: false

  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.WorktreeEngine.WorktreeManager
  alias ProCoder.Actuator.PortWrapper

  @worktree_root "/tmp/procoder/test/worktrees"

  setup_all do
    System.put_env("WORKTREE_ROOT", @worktree_root)
    File.mkdir_p!(@worktree_root)
    
    # Ensure Registry exists for SessionManager
    start_supervised!({Registry, keys: :unique, name: ProCoder.Registry})
    start_supervised!(WorktreeManager)
    start_supervised!({SessionManager, []})

    on_exit(fn ->
      File.rm_rf!(@worktree_root)
    end)

    :ok
  end

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  describe "Concurrent Spawning" do
    test "successfully spawns 100+ agents and registers them" do
      session_ids = Enum.map(1..100, &"batch_session_#{&1}")
      
      tasks = Enum.map(session_ids, fn sid ->
        Task.async(fn ->
          SessionManager.spawn_agent(sid, "test goal")
        end)
      end)

      results = Task.await_many(tasks, 30_000)
      
      assert Enum.all?(results, fn res -> match?({:ok, _pid}, res) end)
      
      Enum.each(session_ids, fn sid ->
        assert {:ok, _} = SessionManager.get_session(sid)
      end)
    end
  end

  describe "Worktree Isolation" do
    test "agents cannot access outside their assigned worktree", %{session_id: sid} do
      {:ok, _pid} = SessionManager.spawn_agent(sid, "test goal")
      {:ok, metadata} = SessionManager.get_session(sid)
      
      # Try to execute a command that tries to write outside the worktree
      {:ok, wrapper} = PortWrapper.start_link([])
      
      # Attempt a touch in a prohibited parent directory
      target_forbidden = Path.join(@worktree_root, "../forbidden_file")
      
      # We check the command result via exit status
      # PortWrapper executes inside bubblewrap, so touch should fail
      _ = PortWrapper.execute(wrapper, "/usr/bin/touch", [target_forbidden], metadata.worktree)
      
      receive do
        {:exit_status, status} -> assert status != 0, "Agent should not be able to write outside worktree"
      after
        5000 -> flunk("Command timed out")
      end
    end
  end

  describe "Fault Recovery and State Consistency" do
    test "supervisor restarts agent on crash and rehydrates state", %{session_id: sid} do
      {:ok, pid} = SessionManager.spawn_agent(sid, "test goal")
      
      # Kill child
      Process.exit(pid, :kill)
      
      # Wait for supervisor restart (transient restart)
      Process.sleep(2000)
      
      # Verify session is still registered in Registry and ETS
      assert {:ok, metadata} = SessionManager.get_session(sid)
      assert is_pid(metadata.pid)
      assert Process.alive?(metadata.pid)
      assert metadata.pid != pid
    end
  end

  describe "Cleanup Logic" do
    test "terminating session removes directory from WORKTREE_ROOT", %{session_id: sid} do
      {:ok, _pid} = SessionManager.spawn_agent(sid, "test goal")
      {:ok, metadata} = SessionManager.get_session(sid)
      
      assert File.exists?(metadata.worktree)
      
      # Simulate cleanup
      WorktreeManager.cleanup_worktree!(sid)
      Process.sleep(500)
      
      refute File.exists?(metadata.worktree)
    end
  end
end
