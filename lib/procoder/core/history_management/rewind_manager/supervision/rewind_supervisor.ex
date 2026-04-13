defmodule ProCoder.Core.HistoryManagement.RewindManager.Supervision.RewindSupervisor do
  @moduledoc """
  The RewindSupervisor serves as the architectural anchor for the Rewind subsystem.
  It orchestrates the lifecycle, fault isolation, and dependency ordering of the
  RewindCoordinator, HistoryStackEngine, and FilesystemReverter components.

  Ensures 'Atomic Revertibility' by supervising processes in a strict topological order
  and providing isolated recovery for each service.
  """

  use Supervisor
  require Logger

  alias ProCoder.Core.HistoryManagement.RewindManager.Coordinator.RewindCoordinator
  alias ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine
  alias ProCoder.Core.HistoryManagement.RewindManager.FsReverter.FilesystemReverter

  @doc """
  Starts the RewindSupervisor for a given session.
  """
  def start_link(session_id) when is_binary(session_id) do
    Supervisor.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @impl true
  def init(session_id) do
    # Validate critical configuration presence before initializing
    worktree_root = Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root]

    if is_nil(worktree_root) do
      Logger.emergency("RewindSupervisor failed to start: WORKTREE_ROOT not configured.")
      :ignore
    else
      children = [
        # Persistence/Stack Engine
        {HistoryStackEngine, [session_id: session_id]},
        # Filesystem Reverter
        {FilesystemReverter, [session_id: session_id, worktree_root: worktree_root]},
        # Coordinator Orchestrator
        {RewindCoordinator, session_id}
      ]

      # Use :one_for_one strategy for isolated failure recovery.
      # Max intensity: 10 restarts / 60 seconds (prevents 'hot-looping').
      Supervisor.init(children,
        strategy: :one_for_one,
        max_restarts: 10,
        max_seconds: 60
      )
    end
  end

  @doc """
  Telemetry hook for monitoring child process health.
  Reports unexpected terminations to the system observability bus.
  """
  def handle_child_termination(session_id, child_module, reason) do
    :telemetry.execute(
      [:procoder, :rewind, :supervisor, :child_terminated],
      %{reason: inspect(reason)},
      %{session_id: session_id, module: child_module}
    )

    if reason != :normal do
      Logger.warn("RewindManager child #{inspect(child_module)} for session #{session_id} terminated: #{inspect(reason)}")
    end
  end

  @doc """
  Maps a session ID to a process registry entry for dynamic lookup.
  """
  def via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "rewind_supervisor_#{session_id}"}}
end
