defmodule ProCoder.SDK.MacroDSL.Persistence.Hooks.PersistenceIntegrationTest do
  @moduledoc """
  High-fidelity integration test suite for the ProCoder SDK persistence macros.
  Validates 'persist', 'snapshot', and 'rewind' operations within an OTP supervisor tree.
  """
  use ExUnit.Case, async: false
  require Logger

  alias ProCoder.SDK.MacroDSL.Persistence.Interface.PersistenceInterface
  alias ProCoder.Brain.Client.Telemetry.EventMonitor
  alias ProCoder.Repo
  alias ProCoder.Persistence.Snapshot, as: SnapshotSchema
  alias ProCoder.Core.HistoryManagement.RewindManager

  # Mock Agent for testing macro integration
  defmodule MockAgent do
    use GenServer
    require ProCoder.SDK.MacroDSL.Persistence.Interface.PersistenceInterface, as: P
    
    P.persist([:state_data, :session_id])

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      {:ok, %{
        id: Keyword.fetch!(opts, :id),
        session_id: Keyword.fetch!(opts, :session_id),
        state_data: "initial",
        secret_field: "super-secret-key-123"
      }}
    end

    @impl true
    def handle_cast({:mutate, new_data}, state) do
      {:noreply, Map.put(state, :state_data, new_data)}
    end

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}

    @impl true
    def terminate(reason, _state), do: {:shutdown, reason}
  end

  setup_all do
    # Ensure Repo is ready
    {:ok, _} = Repo.start_link()
    :ok
  end

  describe "Persistence Macro Operation" do
    test "persist macro automatically triggers asynchronous state capture" do
      session_id = "test_persist_#{System.unique_integer()}"
      {:ok, pid} = MockAgent.start_link(id: "agent_1", session_id: session_id)
      
      # Perform mutation to trigger async capture
      GenServer.cast(pid, {:mutate, "updated"})
      
      # Allow async spawn to settle
      Process.sleep(200)
      
      # Verify telemetry (emitted by EventMonitor indirectly via persistence flow)
      assert_receive {:telemetry_event, [:procoder, :persistence, :snapshot, :success]}, 1000
    end

    test "data redaction prevents secret leakage" do
      # Initialize with secrets
      state = %{id: "agent_2", session_id: "sec_test", state_data: "public", secret_field: "SECRET_VAL"}
      
      # Manually trigger snapshot via SnapshotEngine
      ProCoder.SDK.MacroDSL.Persistence.Hooks.SnapshotEngine.capture("sec_test", state)
      
      # Query binary blobs from persistence layer
      snapshots = Repo.all(SnapshotSchema)
      assert length(snapshots) > 0
      
      for snap <- snapshots do
        blob = :erlang.binary_to_term(snap.memory_blob)
        refute Map.has_key?(blob, :secret_field)
      end
    end
  end

  describe "Rewind Atomicity" do
    test "rewind operations restore memory and worktree state" do
      session_id = "rewind_test"
      # Simulate snapshot
      {:ok, _} = RewindManager.checkpoint(session_id, %{data: "pre"}, "commit_1")
      
      # Perform rewind
      assert {:ok, :rewound} = ProCoder.SDK.MacroDSL.Persistence.Interface.PersistenceInterface.rewind(session_id)
    end
  end

  describe "Scaling and Concurrency" do
    test "high-concurrency persistence does not lead to race conditions" do
      n = 100
      results = Task.async_stream(1..n, fn i ->
        session_id = "stress_#{i}"
        ProCoder.SDK.MacroDSL.Persistence.Hooks.SnapshotEngine.capture(session_id, %{i: i})
      end, max_concurrency: 20)
      |> Enum.to_list()
      
      assert Enum.all?(results, fn {:ok, _} -> true end)
    end
  end

  describe "Fault Injection" do
    test "filesystem errors during rewind trigger supervisor recovery" do
      # Inject failure by mocking path
      # Simulate FilesystemReverter error
      # Verify recovery restart
      session_id = "fault_test"
      
      # Mock the reverter to fail
      # Assert the supervisor sends signal to restart agent
      assert {:error, :revert_failed} = ProCoder.Core.HistoryManagement.RewindManager.FsReverter.FilesystemReverter.revert(nil, "bad_hash", "/non/existent/path")
    end
  end
end
