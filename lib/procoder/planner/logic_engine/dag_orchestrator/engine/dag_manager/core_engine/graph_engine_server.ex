defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.GraphEngineServer do
  @moduledoc """
  The GraphEngineServer is the central cognitive hub for the ProCoder DAG Orchestrator.
  It maintains the state of the execution plan, processes atomic graph mutations,
  and orchestrates task lifecycles through topological validation and persistence.
  """

  use GenServer
  require Logger

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Types

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Validation.GraphValidator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Recovery.RecoveryManager
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Lifecycle.TaskState

  @type t :: pid()

  # --- Client API ---

  @doc "Starts the GraphEngineServer."
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc "Registers a new node in the DAG."
  @spec add_node(pid() | String.t(), map()) :: :ok | {:error, term()}
  def add_node(engine_ref, attrs) do
    GenServer.call(engine_ref, {:add_node, attrs})
  end

  @doc "Registers a dependency edge between nodes."
  @spec add_edge(pid() | String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_edge(engine_ref, from_id, to_id) do
    GenServer.call(engine_ref, {:add_edge, from_id, to_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(session_id) do
    state = Types.new_state(session_id)
    {:ok, state}
  end

  @impl true
  def handle_call({:add_node, attrs}, _from, state) do
    with {:ok, node} <- Types.from_map(attrs),
         true <- !Map.has_key?(state.node_registry, node.id) do
      
      new_registry = Map.put(state.node_registry, node.id, node)
      new_graph = Graph.add_vertex(state.graph, node.id)

      case GraphValidator.validate_all!(new_graph, new_registry) do
        :ok ->
          PersistenceEngine.take_snapshot(self(), new_graph)
          :telemetry.execute([:procoder, :planner, :engine, :node_added], %{id: node.id})
          {:reply, :ok, %{state | node_registry: new_registry, graph: new_graph}}
        {:error, reason, _} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :node_already_exists}, state}
    end
  end

  @impl true
  def handle_call({:add_edge, from_id, to_id}, _from, state) do
    if Map.has_key?(state.node_registry, from_id) and Map.has_key?(state.node_registry, to_id) do
      new_graph = Graph.add_edge(state.graph, from_id, to_id)
      
      case GraphValidator.validate_all!(new_graph, state.node_registry) do
        :ok ->
          PersistenceEngine.take_snapshot(self(), new_graph)
          :telemetry.execute([:procoder, :planner, :engine, :edge_added], %{from: from_id, to: to_id})
          {:reply, :ok, %{state | graph: new_graph}}
        {:error, reason, _} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_node_reference}, state}
    end
  end

  @impl true
  def handle_info({:task_failed, node_id, reason}, state) do
    Logger.error("Node #{node_id} failed: #{inspect(reason)}. Initiating recovery.")
    
    # Trigger recovery via RecoveryManager
    RecoveryManager.remediate(node_id, reason)
    
    # Update node state internally
    new_registry = Map.update!(state.node_registry, node_id, fn node ->
      {:ok, updated} = TaskState.transition(node, :failed)
      updated
    end)
    
    {:noreply, %{state | node_registry: new_registry}}
  end

  # --- Internal Helpers ---

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "engine_#{session_id}"}}
end
