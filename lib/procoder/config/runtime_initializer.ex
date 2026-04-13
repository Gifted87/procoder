defmodule ProCoder.Config.RuntimeInitializer do
  @moduledoc """
  Responsible for boot-time configuration validation and injection.
  Ensures that the environment adheres to the security and operational
  requirements of the ProCoder architecture.
  """
  require Logger

  @doc """
  Initializes global runtime configuration.
  """
  def init_runtime_config! do
    Logger.info("[Config] Initializing runtime configuration...")
    
    # Check for required environment variables
    case System.get_env("PROCODER_LLM_API_KEY") do
      nil -> 
        Logger.warning("[Config] PROCODER_LLM_API_KEY is not set. Some AI features will be disabled.")
      _ -> 
        Logger.info("[Config] PROCODER_LLM_API_KEY detected.")
    end

    # Inject worktree_root for SessionManager/WorktreeManager
    worktree_root = Path.expand(System.get_env("WORKTREE_ROOT") || "/tmp/procoder_worktrees")
    source_root = Path.expand(System.get_env("PROCODER_SOURCE_ROOT") || File.cwd!())
    
    # 3. Persistent Local Storage Resolution
    procoder_dir = Path.join(source_root, ".procoder")
    db_path = Path.join(procoder_dir, "code_graph.db")
    
    unless File.exists?(procoder_dir), do: File.mkdir_p!(procoder_dir)
    
    Application.put_env(:procoder, ProCoder.Repo, [
      database: db_path,
      # pool_size should ideally be dynamic but we'll stick to a safe default here
      pool_size: System.schedulers_online() * 2
    ])

    Application.put_env(:procoder, ProCoder.SessionManager, [
      worktree_root: worktree_root,
      source_root: source_root
    ])
    
    Logger.info("[Config] Worktree root set to: #{worktree_root}")
    Logger.info("[Config] Source root set to: #{source_root}")
    Logger.info("[Config] Local persistence enabled at: #{db_path}")

    :ok
  end
end
