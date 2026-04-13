defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator do
  @moduledoc """
  The Topological Dispatch Sequencer (TDS) is responsible for the orchestration
  of task execution within the ProCoder DAG Orchestrator.

  It interfaces with libgraph for topological sorting, maintains a ready-queue
  of dispatchable nodes, enforces rate-limiting, and manages task lifecycles
  via the SessionManager.
  """

  use GenServer
  require Logger

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator, as: RecoveryManager
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager


  @type state :: %{
    session_id: String.t(),
    active_tasks: map(),
    max_concurrency: pos_integer()
  }

  @doc """
  Starts the DispatchCoordinator.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc """
  Triggers a dispatch cycle to evaluate the DAG and start eligible tasks.
  """
  @spec trigger_dispatch(pid() | String.t()) :: :ok
  def trigger_dispatch(coordinator_ref) do
    GenServer.cast(coordinator_ref, :dispatch_cycle)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(session_id) do
    {:ok, %{
      session_id: session_id,
      active_tasks: %{},
      max_concurrency: 10
    }}
  end

  @impl true
  def handle_cast(:dispatch_cycle, state) do
    try do
      engine_ref = get_engine_ref(state.session_id)
      # Assuming GraphEngineServer exposes :get_state returning {graph, registry}
      {graph, node_registry} = GenServer.call(engine_ref, :get_state)

      ready_nodes = find_ready_nodes(graph, node_registry)
      new_state = process_dispatch_queue(ready_nodes, state)

      {:noreply, new_state}
    rescue
      e ->
        Logger.error("Dispatch cycle failed: #{Exception.message(e)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_completed, node_id}, state) do
    Logger.info("Node #{node_id} completed.")
    update_node_status(state.session_id, node_id, :completed)
    
    # Trigger new dispatch cycle
    trigger_dispatch(self())
    
    {:noreply, %{state | active_tasks: Map.delete(state.active_tasks, node_id)}}
  end

  @impl true
  def handle_info({:task_failed, node_id, reason}, state) do
    Logger.error("Node #{node_id} failed: #{inspect(reason)}")
    update_node_status(state.session_id, node_id, :failed)
    
    engine_ref = get_engine_ref(state.session_id)
    {graph, registry} = GenServer.call(engine_ref, :get_state)
    
    # Trigger Recovery Manager
    RecoveryManager.remediate(get_remediator_ref(state.session_id), node_id, reason, graph, registry)
    
    {:noreply, %{state | active_tasks: Map.delete(state.active_tasks, node_id)}}
  end

  # --- Internal Helpers ---

  defp find_ready_nodes(graph, registry) do
    # Filter nodes with 0 in-degree and status :pending
    graph
    |> Graph.topsort()
    |> Enum.filter(fn node_id ->
      node = Map.get(registry, node_id)
      node && node.status == :pending && Graph.in_degree(graph, node_id) == 0
    end)
  end

  defp process_dispatch_queue(nodes, state) do
    Enum.reduce_while(nodes, state, fn node_id, acc ->
      if map_size(acc.active_tasks) < acc.max_concurrency do
        dispatch_task(node_id, acc.session_id)
        {:cont, %{acc | active_tasks: Map.put(acc.active_tasks, node_id, :running)}}
      else
        {:halt, acc}
      end
    end)
  end

  defp dispatch_task(node_id, session_id) do
    SessionManager.actuate(session_id, node_id)
    :telemetry.execute([:procoder, :planner, :dispatch, :node], %{node_id: node_id})
  end

  defp update_node_status(session_id, node_id, status) do
    engine_ref = get_engine_ref(session_id)
    GenServer.cast(engine_ref, {:update_node_status, node_id, status})
  end

  defp get_engine_ref(session_id), do: {:via, Registry, {ProCoder.Registry, "engine_#{session_id}"}}
  defp get_remediator_ref(session_id), do: {:via, Registry, {ProCoder.Registry, "remediator_#{session_id}"}}
  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "dispatch_#{session_id}"}}
end
