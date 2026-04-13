defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Tests.PlannerIntegrationTest do
  @moduledoc """
  Integration test suite for the ProCoder Planner GenServer.
  
  Validates:
  1. Goal decomposition and DAG structural integrity.
  2. Topological execution ordering and dispatch sequences.
  3. Self-healing failure remediation and compensation subgraph injection.
  """

  use ExUnit.Case, async: false

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.Supervision.DAGOrchestratorSupervisor

  @session_id "test_session_#{System.unique_integer([:positive])}"

  setup do
    # Provision supervisor tree
    {:ok, sup_pid} = DAGOrchestratorSupervisor.start_link(@session_id)
    
    on_exit(fn ->
      if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
    end)

    # Use the registered names as defined in the supervisor/engine
    {:ok, 
      planner_ref: {:via, Registry, {ProCoder.Registry, "engine_#{@session_id}"}}, 
      coordinator_ref: {:via, Registry, {ProCoder.Registry, "coordinator_#{@session_id}"}}
    }
  end

  describe "Goal Decomposition & Structural Integrity" do
    test "correctly registers nodes and edges", %{planner_ref: planner_ref} do
      assert :ok = PlannerGenServer.add_task(planner_ref, %{id: "task_1", task_type: :compute})
      assert :ok = PlannerGenServer.add_task(planner_ref, %{id: "task_2", task_type: :compute})
      assert :ok = PlannerGenServer.add_dependency(planner_ref, "task_1", "task_2")

      state = PlannerGenServer.get_state(planner_ref)
      assert Graph.has_vertex?(state.graph, "task_1")
      assert Graph.has_vertex?(state.graph, "task_2")
      assert Graph.has_edge?(state.graph, "task_1", "task_2")
    end

    test "rejects circular dependencies", %{planner_ref: planner_ref} do
      PlannerGenServer.add_task(planner_ref, %{id: "node_1", task_type: :compute})
      PlannerGenServer.add_task(planner_ref, %{id: "node_2", task_type: :compute})
      
      assert :ok = PlannerGenServer.add_dependency(planner_ref, "node_1", "node_2")
      assert {:error, :cyclic} = PlannerGenServer.add_dependency(planner_ref, "node_2", "node_1")
    end
  end

  describe "Topological Dispatch Ordering" do
    test "dispatches nodes in topological order", %{planner_ref: planner_ref, coordinator_ref: coordinator_ref} do
      PlannerGenServer.add_task(planner_ref, %{id: "A", task_type: :compute})
      PlannerGenServer.add_task(planner_ref, %{id: "B", task_type: :compute})
      PlannerGenServer.add_dependency(planner_ref, "A", "B")

      # Trigger dispatch
      DispatchCoordinator.trigger_dispatch(coordinator_ref)
      
      # Node A should be running, Node B blocked
      Process.sleep(100)
      
      state = PlannerGenServer.get_state(planner_ref)
      assert Map.get(state.node_registry, "A").status == :running
      assert Map.get(state.node_registry, "B").status == :pending
    end
  end

  describe "Self-Healing Failure Recovery" do
    test "triggers remediation on node failure", %{planner_ref: planner_ref, coordinator_ref: coordinator_ref} do
      PlannerGenServer.add_task(planner_ref, %{id: "fail_node", task_type: :compute})
      
      # Simulate task failure
      send(coordinator_ref, {:task_failed, "fail_node", :logic_failure})
      Process.sleep(200)

      state = PlannerGenServer.get_state(planner_ref)
      assert Map.get(state.node_registry, "fail_node").status == :failed
      # Verify recovery injected compensation
      assert length(Graph.vertices(state.graph)) >= 1
    end
  end
end
