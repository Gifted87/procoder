defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator do
  @moduledoc """
  The FailureRemediator module handles autonomous self-healing for the ProCoder DAG Orchestrator.
  It intercepts task failures, performs recursive subgraph traversal to identify impacted nodes,
  and dynamically generates and validates compensation subgraphs to restore system integrity.
  """

  use GenServer
  require Logger


  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Validation.GraphValidator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine

  @type remediation_strategy :: :retry | :cleanup | :rerun | :branch_prune | :diagnostic_only

  @doc """
  Starts the FailureRemediator.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))
  end

  @doc """
  Triggers a remediation sequence for a failing node.
  Offloads the graph traversal and compensation generation to a task.
  """
  @spec remediate(pid() | String.t(), String.t(), atom(), Graph.t(), map()) :: :ok
  def remediate(remediator_ref, node_id, reason, graph, node_registry) do
    GenServer.cast(remediator_ref, {:remediate, node_id, reason, graph, node_registry})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{active_remediations: %{}}}
  end

  @impl true
  def handle_cast({:remediate, node_id, reason, graph, node_registry}, state) do
    Task.start(fn ->
      perform_remediation_workflow(node_id, reason, graph, node_registry)
    end)
    {:noreply, state}
  end

  # --- Internal Logic ---

  defp perform_remediation_workflow(node_id, reason, graph, node_registry) do
    try do
      # 1. Identify impacted subgraph
      impacted_nodes = identify_impacted_subgraph(graph, node_id)

      # 2. Map failure type to compensation strategy
      strategies = select_strategies(reason)

      # 3. Generate Compensation Subgraph
      compensation_dag = generate_compensation_subgraph(node_id, strategies, impacted_nodes)

      # 4. Topological Integrity Check
      case GraphValidator.validate_all!(compensation_dag, node_registry) do
        :ok ->
          # 5. Checkpoint & Actuate
          PersistenceEngine.take_snapshot(self(), compensation_dag)
          Logger.info("Remediation successful for #{node_id}: #{reason}")

        {:error, reason, _} ->
          Logger.error("Compensation DAG validation failed for #{node_id}: #{reason}")
          trigger_escalation(node_id, reason)
      end
    rescue
      e ->
        Logger.error("Critical failure in remediation workflow: #{Exception.message(e)}")
        trigger_escalation(node_id, :remediation_logic_failure)
    end
  end

  defp identify_impacted_subgraph(graph, failed_node_id) do
    # All nodes reachable from the failed node are considered impacted
    Graph.reachable(graph, [failed_node_id])
  end

  defp select_strategies(reason) do
    case reason do
      :io_error -> [:cleanup, :rerun]
      :auth_failure -> [:refresh_auth, :retry]
      :logic_failure -> [:diagnostic_log, :branch_prune]
      _ -> [:retry]
    end
  end

  defp generate_compensation_subgraph(failed_node_id, strategies, impacted_nodes) do
    # Build a compensation DAG: one root remediation node per strategy,
    # chained to a final merge node, replacing impacted downstream nodes.
    base_graph = Graph.new(type: :directed)

    {graph_with_strategies, prev_id} =
      Enum.reduce(strategies, {base_graph, nil}, fn strategy, {g, prev} ->
        node_id = "#{failed_node_id}__#{strategy}"
        g = Graph.add_vertex(g, node_id, label: strategy)
        g = if prev, do: Graph.add_edge(g, prev, node_id), else: g
        {g, node_id}
      end)

    # Attach impacted nodes as dependents of the last strategy node
    Enum.reduce(impacted_nodes, graph_with_strategies, fn impacted_id, g ->
      if impacted_id == failed_node_id do
        g
      else
        g = Graph.add_vertex(g, impacted_id)
        if prev_id, do: Graph.add_edge(g, prev_id, impacted_id), else: g
      end
    end)
  end

  defp trigger_escalation(node_id, reason) do
    # Trigger diagnostic event to avoid recursive failure loops
    :telemetry.execute([:procoder, :planner, :remediation, :escalated], %{node_id: node_id, reason: reason})
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "remediator_#{session_id}"}}
end
