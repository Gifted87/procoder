defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.Requirements.SessionManagerRequirements do
  @moduledoc """
  Mandatory environment requirements and dependency manifest for the ProCoder SessionManager.
  Ensures the environment is securely provisioned, resources are scaled dynamically,
  and essential system tools (Bubblewrap, Registry) are available.
  """

  require Logger

  @type requirement_error :: {:error, atom(), binary()}

  @doc """
  Returns a comprehensive list of OTP and library dependencies required
  for the SessionManager and associated worker processes.
  """
  def dependencies do
    [
      :dynamic_supervisor,
      :registry,
      :ets,
      :telemetry,
      :ecto_sqlite3
    ]
  end

  @doc """
  Returns the structured configuration schema for the SessionManager.
  Used to validate runtime environment configuration.
  """
  def runtime_config_schema do
    %{
      worktree_root: {:required, :string},
      max_workers: {:optional, :integer, 100},
      session_lifecycle_timeout: {:optional, :integer, 30_000},
      max_restarts: {:optional, :integer, 10},
      max_seconds: {:optional, :integer, 60}
    }
  end

  @doc """
  Performs pre-flight environment validation.
  Raises if mandatory constraints are not met.
  """
  def validate_environment! do
    # 1. Validate Worktree Root
    worktree_root = System.get_env("WORKTREE_ROOT")
    validate_worktree_root!(worktree_root)

    # 2. Validate Registry Availability
    unless Process.whereis(ProCoder.Registry) do
      raise "Registry process not available."
    end

    # 3. Validate Sandbox (Bubblewrap)
    unless sandbox_available?() do
      raise "Bubblewrap sandbox utility not found."
    end

    :telemetry.execute([:procoder, :session_manager, :environment, :validated], %{timestamp: DateTime.utc_now()})
    :ok
  end

  @doc """
  Performs a runtime diagnostic check.
  Returns :ok or an error tuple if drift is detected.
  """
  @spec health_check() :: :ok | requirement_error()
  def health_check do
    try do
      validate_environment!()
      :ok
    rescue
      e -> {:error, :env_mismatch, Exception.message(e)}
    end
  end

  # --- Internal Validations ---

  defp validate_worktree_root!(path) when is_nil(path) do
    raise "WORKTREE_ROOT environment variable not set."
  end

  defp validate_worktree_root!(path) do
    abs_path = Path.expand(path)

    # Check for prohibited paths
    if String.starts_with?(abs_path, ["/etc", "/bin", "/usr", "/boot"]) do
      raise "WORKTREE_ROOT '#{path}' resides in a restricted system directory."
    end

    # Check writeability
    case File.mkdir_p!(abs_path) do
      :ok ->
        if File.dir?(abs_path) and File.stat!(abs_path).access == :read_write do
          :ok
        else
          raise "WORKTREE_ROOT '#{path}' is not writeable."
        end
    end
  end

  defp sandbox_available? do
    case System.cmd("which", ["bwrap"]) do
      {_, 0} -> true
      _ -> false
    end
  end
end
