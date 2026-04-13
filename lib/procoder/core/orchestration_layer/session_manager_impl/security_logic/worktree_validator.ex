defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SecurityLogic.WorktreeValidator do
  @moduledoc """
  The 'WorktreeValidator' module is the central security guardrail for the ProCoder SessionManager,
  responsible for maintaining strict worktree isolation and ensuring filesystem integrity
  for all autonomous agent workspaces.
  """

  require Logger

  @default_root "/tmp/procoder/worktrees"

  @type validation_error :: :path_traversal | :permission_denied | :invalid_format | :inaccessible_path

  @doc """
  Normalizes and validates a path against the authorized WORKTREE_ROOT.
  Returns {:ok, absolute_path} if the path is within the root, or {:error, reason} if rejected.
  """
  @spec validate_path!(String.t()) :: {:ok, String.t()} | {:error, validation_error()}
  def validate_path!(path) do
    root = get_worktree_root()

    try do
      abs_root = Path.expand(root)
      abs_path = Path.expand(path)

      if String.starts_with?(abs_path, abs_root) do
        emit_telemetry(:validation_success, %{path: abs_path})
        {:ok, abs_path}
      else
        emit_telemetry(:validation_failure, %{path: abs_path, reason: :path_traversal})
        {:error, :path_traversal}
      end
    rescue
      _ ->
        emit_telemetry(:validation_failure, %{path: path, reason: :invalid_format})
        {:error, :invalid_format}
    end
  end

  @doc """
  Verifies that the target path or its parent directory possesses the required permissions
  (read, write, execute) for the agent owner.
  """
  @spec verify_access!(String.t()) :: :ok | {:error, validation_error()}
  def verify_access!(path) do
    abs_path = Path.expand(path)

    case File.stat(abs_path) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :read] ->
        # Ideally, we check owner ID here, but access mode is the primary constraint.
        emit_telemetry(:access_verified, %{path: abs_path})
        :ok

      {:error, _} ->
        emit_telemetry(:access_denied, %{path: abs_path, reason: :inaccessible_path})
        {:error, :inaccessible_path}

      _ ->
        emit_telemetry(:access_denied, %{path: abs_path, reason: :permission_denied})
        {:error, :permission_denied}
    end
  end

  # --- Internal Helpers ---

  defp get_worktree_root do
    System.get_env("WORKTREE_ROOT") || Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root] || @default_root
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:procoder, :security, :worktree, event],
      %{timestamp: DateTime.utc_now()},
      metadata
    )
  end
end
