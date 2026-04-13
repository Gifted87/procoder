import Config

# ProCoder Runtime Configuration
# This file is evaluated at runtime, after all other configuration files are loaded.
# It is used for dynamic environment-based configuration and sensitive credential injection.

if config_env() == :prod do
  # 1. Mandatory Environment Variables (Fail-Fast Pattern)
  # Production requires explicit API keys; failure to provide will crash the system on startup.
  llm_api_key = System.fetch_env!("PROCODER_LLM_API_KEY")

  # 2. Production Hardening: Dynamic Concurrency & Resource Scaling
  scheduler_count = System.schedulers_online()

  config :procoder, ProCoder.Brain.RateLimiter,
    tokens_per_second: String.to_integer(System.get_env("RATE_LIMIT_TPS", "10")),
    bucket_capacity: String.to_integer(System.get_env("RATE_LIMIT_CAPACITY", "50"))

  config :procoder, ProCoder.SessionManager,
    max_workers: scheduler_count * 10,
    worktree_root: System.get_env("WORKTREE_ROOT", "/tmp/procoder/worktrees")

  # 3. Security: LLM Client Configuration
  config :procoder, ProCoder.Brain.Client,
    api_key: llm_api_key,
    pool_size: scheduler_count * 2

  # 4. Persistence: Data Path Resolution
  config :procoder, ProCoder.Repo,
    database: System.get_env("DATABASE_PATH", "/tmp/procoder/repo/code_graph.db")

  # 5. System Observability
  config :procoder, :telemetry,
    debug_mode: System.get_env("DEBUG_MODE", "false") == "true"

else
  # Development/Test Environment Overrides
  # Use defaults for non-production environments to ensure developer productivity.
  config :procoder, ProCoder.Brain.Client,
    api_key: System.get_env("PROCODER_LLM_API_KEY", "dev_mock_token")

  config :procoder, ProCoder.Repo,
    database: "priv/repo/code_graph_dev.db"

  config :procoder, ProCoder.Search.Coordinator,
    vector_store_threshold: 1.3

  config :procoder, :ml_bridge,
    base_url: "http://localhost:5000"
end
