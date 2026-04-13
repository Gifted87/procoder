defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer do
  @moduledoc """
  The PlannerGenServer serves as the central cognitive orchestrator for task execution within the 
  ProCoder DAG architecture. It manages the full lifecycle of a task plan, state transitions, 
  persistence hooks, and recovery coordination, ensuring fault-tolerant, concurrent orchestration.
  """

  use GenServer
  require Logger

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Types.GraphState
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Validation.GraphValidator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator

  # --- Client API ---

  @doc "Starts the Planner GenServer."
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc "Registers a task node in the graph."
  @spec add_task(pid() | String.t(), map()) :: :ok | {:error, term()}
  def add_task(planner_ref, attrs) do
    GenServer.call(planner_ref, {:add_task, attrs})
  end

  @doc "Registers a dependency between two tasks."
  @spec add_dependency(pid() | String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_dependency(planner_ref, from_id, to_id) do
    GenServer.call(planner_ref, {:add_dependency, from_id, to_id})
  end

  @doc "Retrieves the current graph state."
  @spec get_state(pid() | String.t()) :: GraphState.t()
  def get_state(planner_ref) do
    GenServer.call(planner_ref, :get_state)
  end

  @doc "Gets the next available task from the plan without dispatching it."
  @spec get_next_task(pid() | String.t()) :: {:ok, map()} | {:error, term()}
  def get_next_task(planner_ref) do
    GenServer.call(planner_ref, :get_next_task)
  end

  @doc "Marks a task as completed in the registry."
  @spec mark_task_complete(pid() | String.t(), String.t()) :: :ok | {:error, term()}
  def mark_task_complete(planner_ref, task_id) do
    GenServer.call(planner_ref, {:mark_task_complete, task_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({session_id, global_goal}) do
    {:ok, ProCoder.Planner.LogicEngine.DAGOrchestrator.Types.new_state(session_id, global_goal)}
  end

  def init(session_id) do
    {:ok, ProCoder.Planner.LogicEngine.DAGOrchestrator.Types.new_state(session_id)}
  end

  @impl true
  def handle_call({:add_task, attrs}, _from, state) do
    try do
      # Validate input against TaskNode schema logic
      with {:ok, node} <- ProCoder.Planner.LogicEngine.DAGOrchestrator.Types.from_map(attrs),
           true <- !Map.has_key?(state.node_registry, node.id) do
        
        new_registry = Map.put(state.node_registry, node.id, node)
        new_graph = Graph.add_vertex(state.graph || Graph.new(type: :directed), node.id)

        case GraphValidator.validate_all!(new_graph, new_registry) do
          :ok ->
            PersistenceEngine.take_snapshot(get_persistence_ref(state.session_id), new_graph)
            :telemetry.execute([:procoder, :planner, :orchestrator, :task_added], %{id: node.id})
            {:reply, :ok, %{state | node_registry: new_registry, graph: new_graph}}
          {:error, reason, _details} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
        false -> {:reply, {:error, :duplicate_node}, state}
      end
    rescue
      e ->
        Logger.error("Planner node addition failed: #{Exception.message(e)}")
        {:reply, {:error, :internal_failure}, state}
    end
  end

  @impl true
  def handle_call({:add_dependency, from_id, to_id}, _from, state) do
    try do
      if Map.has_key?(state.node_registry, from_id) and Map.has_key?(state.node_registry, to_id) do
        new_graph = Graph.add_edge(state.graph, from_id, to_id)
        
        case GraphValidator.validate_all!(new_graph, state.node_registry) do
          :ok ->
            PersistenceEngine.take_snapshot(get_persistence_ref(state.session_id), new_graph)
            :telemetry.execute([:procoder, :planner, :orchestrator, :dependency_added], %{from: from_id, to: to_id})
            {:reply, :ok, %{state | graph: new_graph}}
          {:error, reason, _details} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:reply, {:error, :invalid_reference}, state}
      end
    rescue
      e ->
        Logger.error("Planner edge addition failed: #{Exception.message(e)}")
        {:reply, {:error, :internal_failure}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_next_task, _from, state) do
    ready_nodes =
      if state.graph do
        state.graph
        |> Graph.topsort()
        |> Enum.filter(fn node_id ->
          node = Map.get(state.node_registry, node_id)
          node && node.status == :pending && Graph.in_degree(state.graph, node_id) == 0
        end)
      else
        []
      end

    case ready_nodes do
      [next_id | _] -> {:reply, {:ok, Map.get(state.node_registry, next_id)}, state}
      [] -> {:reply, {:error, :no_ready_tasks}, state}
    end
  end

  @impl true
  def handle_call({:mark_task_complete, task_id}, _from, state) do
    case Map.get(state.node_registry, task_id) do
      nil -> {:reply, {:error, :not_found}, state}
      node ->
        updated_node = %{node | status: :completed}
        new_registry = Map.put(state.node_registry, task_id, updated_node)
        
        # Trigger standard completion side-effects (e.g. notifying DispatchCoordinator)
        send(self(), {:task_completed, task_id})
        
        {:reply, :ok, %{state | node_registry: new_registry}}
    end
  end

  @impl true
  def handle_info({:task_failed, node_id, reason}, state) do
    # Trigger autonomous recovery via Remediator
    FailureRemediator.remediate(
      get_remediator_ref(state.session_id), 
      node_id, 
      reason, 
      state.graph, 
      state.node_registry
    )
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_completed, _node_id}, state) do
    # Trigger dispatch cycle check upon completion
    DispatchCoordinator.trigger_dispatch(get_coordinator_ref(state.session_id))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:execute_task, task_node}, state) do
    Logger.info("PlannerGenServer: Received execute_task for #{task_node.id}")
    updated_registry = Map.put(state.node_registry, task_node.id, task_node)
    {:noreply, %{state | node_registry: updated_registry}}
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.debug("PlannerGenServer: unhandled cast: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "planner_#{session_id}"}}

  defp get_coordinator_ref(session_id), do: {:via, Registry, {ProCoder.Registry, "coordinator_#{session_id}"}}
  defp get_remediator_ref(session_id), do: {:via, Registry, {ProCoder.Registry, "remediator_#{session_id}"}}
  defp get_persistence_ref(session_id), do: {:via, Registry, {ProCoder.Registry, "persistence_#{session_id}"}}
end
