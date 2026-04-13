defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.WorktreeEngine.WorktreeManager do
  @moduledoc """
  The WorktreeManager is the foundational infrastructure service responsible for the secure,
  high-concurrency provisioning of isolated Git worktrees.

  As specified in the architectural blueprint, it acts as a gatekeeper for agent filesystem
  isolation, preventing cross-agent contamination and enforcing strict containment
  within a defined WORKTREE_ROOT.
  """

  use GenServer
  require Logger

  @type session_id :: String.t()
  @type worktree_path :: Path.t()

  # --- API ---

  @doc """
  Starts the WorktreeManager GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Provisions a new, isolated worktree for a given session.
  Returns {:ok, absolute_path} or {:error, reason}.
  """
  @spec provision_worktree!(session_id()) :: {:ok, worktree_path()} | {:error, term()}
  def provision_worktree!(session_id) do
    GenServer.call(__MODULE__, {:provision, session_id}, 60_000)
  end

  @doc """
  Initiates asynchronous removal of a worktree for a terminated session.
  """
  @spec cleanup_worktree!(session_id()) :: :ok
  def cleanup_worktree!(session_id) do
    GenServer.cast(__MODULE__, {:cleanup, session_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    worktree_root = Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root]
    
    case validate_environment!(worktree_root) do
      :ok ->
        table = :ets.new(:worktree_registry, [:set, :protected, :named_table, read_concurrency: true])
        {:ok, %{root: Path.expand(worktree_root), registry: table}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:provision, session_id}, _from, state) do
    path = Path.join(state.root, session_id)
    abs_path = Path.expand(path)

    case validate_containment(abs_path, state.root) do
      :ok ->
        if :ets.member(state.registry, session_id) do
          [{^session_id, existing_path}] = :ets.lookup(state.registry, session_id)
          {:reply, {:ok, existing_path}, state}
        else
          case create_worktree(abs_path) do
            :ok ->
              :ets.insert(state.registry, {session_id, abs_path})
              emit_telemetry(:provisioned, session_id, abs_path)
              {:reply, {:ok, abs_path}, state}
            {:error, reason} ->
              emit_telemetry(:provision_failed, session_id, abs_path, reason)
              {:reply, {:error, reason}, state}
          end
        end
      {:error, reason} ->
        emit_telemetry(:security_violation, session_id, abs_path, reason)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:cleanup, session_id}, state) do
    case :ets.lookup(state.registry, session_id) do
      [{^session_id, path}] ->
        source_root = Application.get_env(:procoder, ProCoder.SessionManager)[:source_root]
        Task.start(fn -> 
          # Properly remove worktree from git tracking and filesystem
          System.cmd("git", ["worktree", "remove", "--force", path], cd: source_root)
          System.cmd("git", ["worktree", "prune"], cd: source_root)
          
          case File.rm_rf(path) do
            {:ok, _} -> emit_telemetry(:cleaned, session_id, path)
            {:error, reason} -> emit_telemetry(:cleanup_failed, session_id, path, reason)
          end
        end)
        :ets.delete(state.registry, session_id)
      [] ->
        :ok
    end
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp validate_environment!(root) when is_nil(root), do: {:error, :worktree_root_not_configured}
  defp validate_environment!(root) do
    abs_root = Path.expand(root)
    case File.mkdir_p!(abs_root) do
      :ok -> 
        if File.dir?(abs_root) and File.stat!(abs_root).access in [:read_write, :read_write_execute] do
          :ok
        else
          {:error, :worktree_root_not_writable}
        end
      _ -> {:error, :worktree_root_creation_failed}
    end
  end

  defp validate_containment(path, root) do
    if String.starts_with?(path, root) do
      :ok
    else
      {:error, :unauthorized_access}
    end
  end

  defp create_worktree(path) do
    source_root = Application.get_env(:procoder, ProCoder.SessionManager)[:source_root]

    if is_nil(source_root) do
      {:error, "source_root is not configured. Set `config :procoder, ProCoder.SessionManager, source_root: \"/path/to/project\"` in your config."}
    else
      try do
        branch_name = "procoder_session_#{Path.basename(path)}"

        # 1. Clean up stale worktree registry/directory/branch if it exists
        System.cmd("git", ["worktree", "remove", "--force", path], cd: source_root, stderr_to_stdout: true)
        System.cmd("git", ["branch", "-D", branch_name], cd: source_root, stderr_to_stdout: true)
        System.cmd("git", ["worktree", "prune"], cd: source_root)
        File.rm_rf(path)

        # 2. Add as a worktree to the sandbox path
        case System.cmd("git", ["rev-parse", "HEAD"], cd: source_root, stderr_to_stdout: true) do
          {_, 0} ->
            case System.cmd("git", ["worktree", "add", "-b", branch_name, path], cd: source_root, stderr_to_stdout: true) do
              {_, 0} -> :ok
              {output, _} -> {:error, "Git worktree failed (Normal): #{output}"}
            end
          {_, _} ->
            case System.cmd("git", ["worktree", "add", "--orphan", "-b", branch_name, path], cd: source_root, stderr_to_stdout: true) do
              {_, 0} -> :ok
              {output, _} -> {:error, "Git worktree failed (Orphan): #{output}"}
            end
        end
      rescue
        e -> {:error, Exception.message(e)}
      end
    end
  end

  defp emit_telemetry(action, session_id, path, reason \\ nil) do
    :telemetry.execute(
      [:procoder, :worktree_manager, action],
      %{timestamp: DateTime.utc_now()},
      %{session_id: session_id, path: path, reason: reason}
    )
  end
end
