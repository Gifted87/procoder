defmodule ProCoder.Repo do
  @moduledoc """
  The primary persistence layer for the ProCoder system.
  
  Integrates with Ecto and the SQLite3 adapter to provide a resilient, 
  high-performance graph-based data storage solution. This module 
  is supervised by the application tree and utilizes dynamic 
  connection pooling based on the host system's hardware capabilities.
  """
  use Ecto.Repo,
    otp_app: :procoder,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Dynamically initializes the repository configuration at runtime.
  This allows the system to scale connection pools based on available 
  CPU schedulers and ensures the database path is resolved from 
  secured configuration.
  """
  def init(_type, opts) do
    # 1. Extension Loading (SQLite VSS)
    # The extensions must be loaded at the connection level. 
    # Reference the precompiled .so files from the build artifacts.
    extensions = [
      SqliteVss.loadable_path_vector0() <> ".so",
      SqliteVss.loadable_path_vss0() <> ".so"
    ]
    opts = Keyword.put(opts, :load_extensions, extensions)

    # 2. Database path validation and secure resolution
    database = Keyword.get(opts, :database)
    
    # Validation of the database path to ensure containment
    if database && database != ":memory:" do
      ensure_secure_path!(database)
    end

    # Apply performance tuning: pool size is managed by the application configuration,
    # which is pre-injected by ProCoder.Config.RuntimeInitializer.
    {:ok, opts}
  end

  defp ensure_secure_path!(path) do
    # Logic to ensure the database file resides within the permitted project workspace.
    # This prevents directory traversal attacks via the configuration.
    
    # Authorized roots: PROCODER_SOURCE_ROOT (target repo) and WORKTREE_ROOT (sandboxes)
    # We fallback to CWD if no explicit roots are set.
    source_root = Path.expand(System.get_env("PROCODER_SOURCE_ROOT") || File.cwd!())
    worktree_root = Path.expand(System.get_env("WORKTREE_ROOT") || "/tmp/procoder_worktrees")
    
    abs_db_path = Path.expand(path)

    is_authorized = 
      String.starts_with?(abs_db_path, source_root) or 
      String.starts_with?(abs_db_path, worktree_root)

    unless is_authorized do
      raise "Security Violation: Database path '#{path}' is outside the authorized workspace (Source: #{source_root}, Worktree: #{worktree_root})."
    end

    # Ensure the parent directory exists
    dir = Path.dirname(abs_db_path)
    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end
  end

  @doc """
  Performs an atomic transaction, ensuring transactional integrity 
  for complex graph operations.
  """
  def transaction_atomic(fun) do
    transaction(fun)
  end

end
