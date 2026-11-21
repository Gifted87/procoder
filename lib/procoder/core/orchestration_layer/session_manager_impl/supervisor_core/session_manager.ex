defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager do
  @moduledoc """
  The SessionManager acts as the primary runtime orchestrator for autonomous coding agents 
  within the ProCoder swarm architecture. By leveraging a DynamicSupervisor pattern, 
  it provides robust, high-concurrency life-cycle management for ephemeral agent instances, 
  ensuring that each worker process remains isolated within a sandboxed Git worktree.
  """

  use DynamicSupervisor
  require Logger

  alias ProCoder.Core.AgentFSM
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.WorktreeEngine.WorktreeManager
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.Requirements.SessionManagerRequirements

  @table_name :session_registry
  @telemetry_prefix [:procoder, :session_manager]

  # --- API ---

  @doc """
  Starts the SessionManager supervisor.
  """
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initiates the provisioning and spawning of a new autonomous agent.
  Possible options:
    - `force_fresh: true` - skip history hydration and start clean.
  """
  @spec spawn_agent(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent(session_id, goal, opts \\ []) do
    Task.async(fn ->
      provision_and_spawn(session_id, goal, opts)
    end)
    |> Task.await(60_000)
  end

  @doc """
  Terminates an active agent session and its associated resources.
  """
  def terminate_session(session_id) do
    case get_session(session_id) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        Logger.info("[SessionManager] Terminating session #{session_id} (PID: #{inspect(pid)})")
        GenServer.cast(pid, :stop)
        :ets.delete(@table_name, session_id)
        :ok
      {:ok, _} ->
        :ets.delete(@table_name, session_id)
        :ok
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Retrieves metadata for an active session.
  """
  def get_session(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, metadata}] -> {:ok, metadata}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all active agent sessions in the swarm.
  """
  def list_active_agents do
    sessions = :ets.tab2list(@table_name) |> Enum.map(fn {_, metadata} -> metadata end)
    {:ok, sessions}
  end

  @doc """
  Acts as the primary bridge for task actuation from the DispatchCoordinator.
  """
  @spec actuate(String.t(), map()) :: :ok | {:error, term()}
  def actuate(session_id, task_node) do
    case get_session(session_id) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        # Send the task to the AgentFSM for execution
        GenServer.cast(pid, {:execute_task, task_node})
      error -> error
    end
  end

  @doc """
  Validates if a worktree is authorized for the given session.
  Used as a security gate in the Search and Actuator layers.
  """
  @spec authorized?(String.t()) :: boolean()
  def authorized?(session_id) do
    case get_session(session_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # --- DynamicSupervisor Callbacks ---

  @impl true
  def init(_opts) do
    # Validate environment before proceeding
    SessionManagerRequirements.validate_environment!()

    :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
    
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # --- Internal Logic ---

  defp provision_and_spawn(session_id, goal, opts) do
    emit_telemetry(:provisioning_start, %{session_id: session_id})

    with {:ok, worktree} <- WorktreeManager.provision_worktree!(session_id),
         {:ok, _history_pid} <- start_history_stack(session_id),
         {:ok, _cache_pid} <- start_cache_engine(session_id),
         {:ok, _planner_pid} <- start_planner_supervisor(session_id) do

      source_root = Application.get_env(:procoder, ProCoder.SessionManager)[:source_root]

      # Pre-register session BEFORE starting agent to avoid race condition
      # where SearchCoordinator.authorized?/1 returns false during Discovery
      pre_register_session(session_id, worktree)
      
      case start_agent_process(session_id, worktree, goal, source_root, opts) do
        {:ok, pid} ->
          # Update the ETS entry with the real PID
          update_session_pid(session_id, pid)
          emit_telemetry(:provisioning_success, %{session_id: session_id, pid: pid})
          {:ok, pid}
        {:error, reason} ->
          # Clean up pre-registration on failure
          :ets.delete(@table_name, session_id)
          emit_telemetry(:spawn_failure, %{session_id: session_id, reason: reason})
          {:error, reason}
      end
    else
      {:error, reason} ->
        emit_telemetry(:spawn_failure, %{session_id: session_id, reason: reason})
        {:error, reason}
    end 
  end

  defp start_agent_process(session_id, worktree, goal, source_root, opts) do
    module = Keyword.get(opts, :module, AgentFSM)
    specialist_module = Keyword.get(opts, :specialist_module)
    actual_specialist = specialist_module || (if module != AgentFSM, do: module, else: nil)

    agent_opts = [
      session_id: session_id,
      worktree_root: worktree,
      goal: goal,
      source_root: source_root,
      specialist_module: actual_specialist
    ] ++ opts

    start_mfa =
      cond do
        is_atom(module) and module != AgentFSM and Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1) ->
          {module, :start_link, [agent_opts]}

        true ->
          {AgentFSM, :start_link, [agent_opts]}
      end

    child_spec = %{
      id: {:agent_fsm, session_id},
      start: start_mfa,
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        # Trigger the initial planning phase
        GenServer.cast(pid, {:plan, goal})
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        GenServer.cast(pid, {:plan, goal})
        {:ok, pid}
      error -> error
    end
  end

  defp start_history_stack(session_id) do
    child_spec = %{
      id: "history_stack_#{session_id}",
      start: {ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine, :start_link, [[session_id: session_id]]},
      restart: :transient
    }
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp start_cache_engine(session_id) do
    child_spec = %{
      id: "cache_#{session_id}",
      start: {ProCoder.Brain.MemoryStore.Cache.CacheEngine, :start_link, [session_id]},
      restart: :transient
    }
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp start_planner_supervisor(session_id) do
    child_spec = %{
      id: "planner_supervisor_#{session_id}",
      start: {ProCoder.SupervisionTree.RootSupervisor.Planner.PlannerSupervisor, :start_link, [[session_id: session_id]]},
      restart: :transient,
      type: :supervisor
    }
    
    # We start it under the centralized Planner.DynamicSupervisor
    case DynamicSupervisor.start_child(ProCoder.Planner.DynamicSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp pre_register_session(session_id, worktree) do
    _ = &register_session/3
    metadata = %{
      session_id: session_id,
      worktree: worktree,
      pid: nil,
      status: :provisioning,
      started_at: DateTime.utc_now()
    }
    :ets.insert(@table_name, {session_id, metadata})
  end

  defp register_session(session_id, worktree, pid) do
    metadata = %{
      session_id: session_id,
      worktree: worktree,
      pid: pid,
      status: :provisioning,
      started_at: DateTime.utc_now()
    }
    :ets.insert(@table_name, {session_id, metadata})
  end


  defp update_session_pid(session_id, pid) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, metadata}] ->
        :ets.insert(@table_name, {session_id, %{metadata | pid: pid, status: :active}})
      [] ->
        :ok
    end
  end



  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      %{timestamp: DateTime.utc_now()},
      metadata
    )
  end
end
