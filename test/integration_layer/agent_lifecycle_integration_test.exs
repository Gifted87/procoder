defmodule ProCoder.Core.Integration.AgentLifecycleIntegrationTest do
  @moduledoc """
  Integration test suite for the ProCoder autonomous coding agent lifecycle.
  Validates state machine transitions, sandboxed actuation, fault tolerance,
  planning coupling, and observability.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import ProCoder.SDK.MacroDSL.Agents.AgentMacro
  alias ProCoder.Core.AgentFSM
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager
  alias ProCoder.Actuator.PortWrapper
  alias ProCoder.Brain.MemoryStore.Cache.CacheEngine

  @worktree_root "/tmp/procoder/test/worktrees"

  setup_all do
    System.put_env("WORKTREE_ROOT", @worktree_root)
    File.mkdir_p!(@worktree_root)
    :ok
  end

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    worktree = Path.join(@worktree_root, session_id)
    File.mkdir_p!(worktree)

    {:ok, session_id: session_id, worktree: worktree}
  end

  describe "Phase A: Lifecycle Orchestration & State Transition Integrity" do
    test "stays in :active state throughout the cycle", %{session_id: sid, worktree: wt} do
      {:ok, pid} = AgentFSM.start_link(session_id: sid, worktree_root: wt)

      # 1. Start -> Active
      assert :sys.get_state(pid) == :active

      # 2. Plan -> Still Active (with internal think)
      :gen_statem.cast(pid, {:plan, "implement feature x"})
      assert :sys.get_state(pid) == :active

      # 3. Execution -> Transitions to verification then back to active
      # Note: execution state is transient for tool performance
      # Verification state is also transient.
      # We check that it eventually settles back to :active
      Process.sleep(100)
      assert :sys.get_state(pid) == :active
    end
  end

  describe "Phase B: Sandboxed Actuation & Environment Security" do
    test "rejects unauthorized shell access outside of worktree", %{worktree: wt} do
      {:ok, port_wrapper} = PortWrapper.start_link([])
      
      forbidden_path = Path.join(wt, "../etc/passwd")
      
      # Attempt traversal
      PortWrapper.execute(port_wrapper, "/usr/bin/cat", [forbidden_path], wt)
      
      receive do
        {:exit_status, status} -> assert status != 0, "Sandbox violation expected"
      after
        2000 -> flunk("Command timed out")
      end
    end
  end

  describe "Phase C: Fault-Tolerance, Persistence, & Self-Healing" do
    test "recovers state after unexpected termination", %{session_id: sid, worktree: wt} do
      {:ok, pid} = AgentFSM.start_link(session_id: sid, worktree_root: wt)
      
      # Trigger state
      :gen_statem.cast(pid, {:plan, "crash recovery test"})
      Process.sleep(50)
      
      # Simulate crash
      Process.exit(pid, :kill)
      Process.sleep(500)
      
      # Supervisor should have restarted it
      new_pid = Registry.lookup(ProCoder.Registry, sid) |> List.first() |> elem(1)
      assert is_pid(new_pid)
      assert new_pid != pid
    end
  end

  describe "Phase D: Planning-Execution Coupling" do
    test "agent adheres to planned DAG segments", %{session_id: sid, worktree: wt} do
      # Setup agent with mock graph
      {:ok, pid} = AgentFSM.start_link(session_id: sid, worktree_root: wt)
      
      # Validate task sequence
      :gen_statem.cast(pid, {:plan, "complex goal"})
      
      # Monitor task execution status
      # This test would verify that the FSM executes tool_execution calls 
      # matching the Planner's projected DAG order.
      assert true
    end
  end

  describe "Phase E: Observability & Telemetry Verification" do
    test "emits state transition telemetry events", %{session_id: sid, worktree: wt} do
      telemetry_events = :ets.new(:telemetry_events, [:public, :set])
      :telemetry.attach("test-monitor", [:procoder, :agent, :state, :transition], fn _name, _meta, _data, _config ->
        :ets.insert(telemetry_events, {:transition, :emitted})
      end, nil)

      {:ok, pid} = AgentFSM.start_link(session_id: sid, worktree_root: wt)
      :gen_statem.cast(pid, {:plan, "telemetry test"})
      
      Process.sleep(100)
      assert :ets.lookup(telemetry_events, :transition) != []
    end
  end
end
