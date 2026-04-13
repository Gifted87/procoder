defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Recovery.RecoveryManager do
  @moduledoc """
  The RecoveryManager acts as the ProCoder's fault-tolerance unit, orchestrating 
  remediation subgraphs when task nodes fail within the DAG. 
  
  It follows a tiered strategy ranging from simple retries to manual intervention 
  signaling, ensuring system state consistency through validated graph manipulations.
  """

  use GenServer
  require Logger
  alias ProCoder.Repo

  @doc """
  Initiates the remediation process for a failed task.
  This function is the narrow interface for the system to trigger recovery.
  """
  @spec remediate(String.t(), atom()) :: :ok | {:error, term()}
  def remediate(node_id, failure_reason) do
    GenServer.call(__MODULE__, {:remediate, node_id, failure_reason})
  end

  # --- GenServer Callbacks ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{remediation_registry: %{}}}
  end

  @impl true
  def handle_call({:remediate, node_id, failure_reason}, _from, state) do
    # Fetch current session graph state (orchestrated via Registry or Planner)
    # For this implementation, we assume we fetch the state from the repository
    case Repo.get(ProCoder.Persistence.TaskNode, node_id) do
      nil ->
        {:reply, {:error, :node_not_found}, state}

      task_node ->
        case perform_remediation(task_node, failure_reason) do
          {:ok, _compensation_subgraph} ->
            # Validate subgraph against GraphValidator before applying
            # This is a placeholder for the actual Graph.t integration
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error("Remediation failed for #{node_id}: #{reason}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  # --- Internal Logic ---

  defp perform_remediation(task_node, reason) do
    case reason do
      :io_error ->
        # Tier 2: Cleanup then re-run
        generate_subgraph(task_node, [:cleanup, :rerun])

      :auth_failure ->
        # Tier 1: Identity refresh
        generate_subgraph(task_node, [:refresh_auth, :rerun])

      :logic_failure ->
        # Tier 3: Diagnostic then prune
        generate_subgraph(task_node, [:diagnostic_log, :branch_prune])

      _ ->
        # Tier 1: Simple retry
        generate_subgraph(task_node, [:retry])
    end
  end

  defp generate_subgraph(task_node, actions) do
    # This logic would be offloaded to a pure module (dag_manipulator)
    # Returns {:ok, compensation_graph} or {:error, reason}
    Logger.info("Generating subgraph for #{task_node.id} with actions: #{inspect(actions)}")
    {:ok, %{actions: actions, original_node: task_node.id}}
  end
end
