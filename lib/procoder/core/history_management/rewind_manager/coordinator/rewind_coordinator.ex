defmodule ProCoder.Core.HistoryManagement.RewindManager.Coordinator.RewindCoordinator do
  @moduledoc """
  The RewindCoordinator orchestrates atomic transitions between system memory state 
  and filesystem worktrees. It guarantees synchronization by coordinating the 
  HistoryStackEngine, FilesystemReverter, and MemorySnapshotManager.
  """

  use GenServer
  require Logger

  alias ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine
  alias ProCoder.Core.HistoryManagement.RewindManager.FsReverter.FilesystemReverter
  alias ProCoder.Core.HistoryManagement.RewindManager.MemorySnapshotManager

  @doc """
  Initializes the RewindCoordinator for a given session.
  Links the process to the ProCoder.Registry.
  """
  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc """
  Requests a rollback to a specific snapshot.
  Blocks until the sequence completes or times out.
  """
  def rewind(session_id, snapshot_id) do
    GenServer.call(via_tuple(session_id), {:rewind, snapshot_id}, 60_000)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(session_id) do
    {:ok, %{session_id: session_id}}
  end

  @impl true
  def handle_call({:rewind, snapshot_id}, _from, state) do
    :telemetry.execute([:procoder, :rewind, :start], %{snapshot_id: snapshot_id})

    result = perform_rollback_sequence(state.session_id, snapshot_id)

    case result do
      {:ok, :rewound} ->
        :telemetry.execute([:procoder, :rewind, :success], %{snapshot_id: snapshot_id})
        {:reply, {:ok, :rewound}, state}

      {:error, reason} ->
        :telemetry.execute([:procoder, :rewind, :failure], %{snapshot_id: snapshot_id, reason: inspect(reason)})
        Logger.critical("Critical rewind failure for session #{state.session_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # --- Internal Logic ---

  defp perform_rollback_sequence(session_id, snapshot_id) do
    worktree_root = get_worktree_root()

    with :ok <- validate_worktree_path!(worktree_root),
         {:ok, snapshot} <- HistoryStackEngine.get(session_id, snapshot_id),
         :ok <- FilesystemReverter.revert(nil, snapshot.git_commit, worktree_root),
         {:ok, _context} <- MemorySnapshotManager.deserialize_state(snapshot.memory_blob) do
      {:ok, :rewound}
    else
      error -> error
    end
  end

  defp validate_worktree_path!(path) do
    base = Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root]
    if String.starts_with?(Path.expand(path), Path.expand(base)) do
      :ok
    else
      {:error, :unauthorized_worktree}
    end
  end

  defp get_worktree_root do
    Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root]
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "rewind_coord_#{session_id}"}}
end
