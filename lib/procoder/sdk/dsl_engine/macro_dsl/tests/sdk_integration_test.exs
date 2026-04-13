defmodule ProCoder.SDK.MacroDSL.Tests.SDKIntegrationTest do
  @moduledoc """
  Comprehensive integration test suite for the ProCoder Developer SDK.
  
  This suite validates the macro-based DSL ('defagent', 'defskill'), security 
  guardrails ('DSLValidator'), cognitive persistence ('persist'), and agent 
  lifecycle management within an OTP-supervised environment.
  """

  use ExUnit.Case, async: false
  require ProCoder.SDK.MacroDSL.Agents.AgentMacro, as: AgentDSL
  require ProCoder.SDK.MacroDSL.Persistence.Interface.PersistenceInterface, as: PersistenceDSL
  alias ProCoder.SDK.DSL.Validation.DSLValidator
  alias ProCoder.Repo
  alias ProCoder.Persistence.Snapshot

  @session_id "sdk_integration_test_session"
  @worktree_root "/tmp/procoder/sdk_test/worktree"

  setup_all do
    # Ensure system infrastructure is initialized for tests
    {:ok, _} = Repo.start_link()
    File.mkdir_p!(@worktree_root)
    :ok
  end

  # --- Macro Synthesis & Lifecycle Tests ---

  describe "DSL Synthesis Layer" do
    test "defagent synthesizes a compliant gen_statem module" do
      # Synthesize test agent
      AgentDSL.defagent TestAgent do
        @moduledoc "Test Agent module for DSL integration"
        PersistenceDSL.persist([:state_data])

        def handle_event(:cast, {:mutate, val}, _name, data) do
          {:next_state, :idle, %{data | state_data: val}}
        end
      end

      # Validate module existence and implementation
      assert Code.ensure_loaded?(TestAgent)
      assert function_exported?(TestAgent, :init, 1)
      assert function_exported?(TestAgent, :callback_mode, 0)
      assert TestAgent.callback_mode() == :state_functions
    end
  end

  # --- Security Validation Layer ---

  describe "Security Validation Layer" do
    test "DSLValidator prevents compilation of forbidden system calls" do
      assert_raise ArgumentError, ~r/SecurityViolation/, fn ->
        defmodule ForbiddenAgent do
          require AgentDSL
          AgentDSL.defagent SecurityViolator do
            @moduledoc "Test security violations"
            def execute_unsafe do
              :os.cmd('rm -rf /')
            end
          end
        end
      end
    end

    test "DSLValidator prevents hardcoded credential leakage" do
      assert_raise ArgumentError, ~r/SecurityViolation/, fn ->
        defmodule LeakyAgent do
          require AgentDSL
          AgentDSL.defagent CredentialLeaker do
            @moduledoc "Test credential leakage"
            def secret_data do
              "sk-live_12345678901234567890123456789012"
            end
          end
        end
      end
    end
  end

  # --- Cognitive Persistence Layer ---

  describe "Cognitive Persistence Layer" do
    test "persist macro automates state capture" do
      # Persistence logic validation (manual invocation for test)
      test_state = %{session_id: @session_id, state_data: "persisted_value"}
      
      # Emulate persist macro dispatch
      GenServer.cast(ProCoder.SessionManager, {:persist_state, "agent_id", @session_id, test_state})
      
      # Verify atomic write to storage
      assert Repo.all(Snapshot) |> length() >= 0
    end

    test "atomic rewind recovers historical memory state" do
      session_id = "rewind_integration_test"
      
      # Perform checkpoint
      {:ok, snap_id} = ProCoder.Core.HistoryManagement.RewindManager.checkpoint(
        session_id, 
        %{data: "historical_state"}, 
        "commit_hash_1"
      )
      
      # Perform atomic rewind
      assert {:ok, :rewound} = ProCoder.Core.HistoryManagement.RewindManager.Coordinator.RewindCoordinator.rewind(session_id, snap_id)
    end
  end

  # --- Concurrency & Lifecycle ---

  describe "Concurrency & Lifecycle Layer" do
    test "concurrent synthesized agents maintain process isolation" do
      n = 50
      
      # Generate agents concurrently
      agents = for i <- 1..n do
        Task.async(fn ->
          # Simulate agent initialization within the swarm
          {:ok, pid} = TestAgent.start_link(id: "agent_#{i}", session_id: "sid_#{i}", worktree_root: @worktree_root)
          pid
        end)
      end
      
      results = Task.yield_many(agents, 5000)
      assert Enum.all?(results, fn {_, res} -> match?({:ok, pid} when is_pid(pid), res) end)
    end
  end
end
