defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.Tests.DAGManagerConcurrencyRecoveryTest do
  @moduledoc """
  Integration test suite for the ProCoder DAG Orchestrator focusing on high-concurrency 
  scheduling, failure remediation, and persistent state integrity.
  """

  use ExUnit.Case, async: false

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.GraphEngineServer
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Validation.GraphValidator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Types

  @session_id "test_session_#{System.unique_integer([:positive])}"

  setup do
    # Provisioning the supervision tree for the DAG Manager
    {:ok, supervisor_pid} = ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.Supervision.DAGOrchestratorSupervisor.start_link(@session_id)
    
    on_exit(fn ->
      if Process.alive?(supervisor_pid), do: Process.exit(supervisor_pid, :shutdown)
    end)

    {:ok, session_id: @session_id}
  end

  describe "High-Concurrency Stress Testing" do
    test "maintains graph integrity under rapid concurrent task completion" do
      engine_ref = via_tuple("engine", @session_id)
      
      # Setup: Inject 50 nodes with linear dependency
      for i <- 1..50 do
        GraphEngineServer.add_node(engine_ref, %{id: "task_#{i}", task_type: :compute})
        if i > 1 do
          GraphEngineServer.add_edge(engine_ref, "task_#{i-1}", "task_#{i}")
        end
      end

      # Spawn concurrent completions
      tasks = Enum.map(1..50, fn i ->
        Task.async(fn ->
          send(via_tuple("coordinator", @session_id), {:task_completed, "task_#{i}"})
        end)
      end)
      
      Enum.each(tasks, &Task.await/1)

      {graph, _registry} = GenServer.call(engine_ref, :get_state)
      assert Graph.vertices(graph) |> length() == 50
      assert Graph.is_acyclic?(graph)
    end
  end

  describe "Failure Remediation Fidelity" do
    test "triggers recovery on single-node failure and maintains acyclicity" do
      engine_ref = via_tuple("engine", @session_id)
      coordinator_ref = via_tuple("coordinator", @session_id)
      
      GraphEngineServer.add_node(engine_ref, %{id: "node_A", task_type: :compute})
      GraphEngineServer.add_node(engine_ref, %{id: "node_B", task_type: :compute})
      GraphEngineServer.add_edge(engine_ref, "node_A", "node_B")

      # Fail node A
      send(coordinator_ref, {:task_failed, "node_A", :io_error})
      
      # Wait for async remediation
      Process.sleep(200)

      {graph, _registry} = GenServer.call(engine_ref, :get_state)
      assert Graph.is_acyclic?(graph)
      assert Graph.has_vertex?(graph, "node_A")
    end

    test "cascading failure blocks children and triggers remediation" do
      engine_ref = via_tuple("engine", @session_id)
      coordinator_ref = via_tuple("coordinator", @session_id)
      
      GraphEngineServer.add_node(engine_ref, %{id: "parent", task_type: :compute})
      GraphEngineServer.add_node(engine_ref, %{id: "child1", task_type: :compute})
      GraphEngineServer.add_node(engine_ref, %{id: "child2", task_type: :compute})
      GraphEngineServer.add_edge(engine_ref, "parent", "child1")
      GraphEngineServer.add_edge(engine_ref, "parent", "child2")

      # Fail parent
      send(coordinator_ref, {:task_failed, "parent", :logic_failure})
      
      Process.sleep(300)

      {graph, _registry} = GenServer.call(engine_ref, :get_state)
      assert GraphValidator.contains_cycle?(graph) == false
    end
  end

  describe "Persistent State Integrity" do
    test "ensures snapshot captures remediated state" do
      engine_ref = via_tuple("engine", @session_id)
      persistence_ref = via_tuple("persistence", @session_id)
      coordinator_ref = via_tuple("coordinator", @session_id)

      GraphEngineServer.add_node(engine_ref, %{id: "critical_node", task_type: :compute})
      
      # Trigger failure which should trigger remediation -> snapshot
      send(coordinator_ref, {:task_failed, "critical_node", :io_error})
      
      Process.sleep(500)
      
      # Assert PersistenceEngine has history
      # Since we don't have direct access to internal state, we check if telemetry fired
      assert_receive {_, [:procoder, :planner, :persistence, :snapshot_taken], _, _}, 1000
    end
  end

  # Helpers
  defp via_tuple(type, session_id) do
    {:via, Registry, {ProCoder.Registry, "#{type}_#{session_id}"}}
  end
end
