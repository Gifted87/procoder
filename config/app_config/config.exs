import Config

# ProCoder Base Configuration
# This file defines global defaults. Environment-specific overrides
# are handled in dev.exs, prod.exs, and test.exs.

# SessionManager Configuration
config :procoder, ProCoder.SessionManager,
  max_workers: 100,
  worktree_root: "/tmp/procoder/worktrees"

# Finch HTTP Client Pools
config :procoder, ProCoder.Brain.Client,
  pool_size: 50,
  max_overflow: 10

# PromptEngine Salience Weights
config :procoder, ProCoder.Brain.PromptEngine,
  context_salience_threshold: 0.75,
  max_tokens_per_prompt: 4096

# Gradient of Precision Search Configuration
config :procoder, ProCoder.Search.Coordinator,
  lsp_timeout: 5000,
  ripgrep_path: "/usr/bin/rg",
  vector_store_threshold: 1.5

# CodeGraph Persistence (SQLite)
config :procoder, ProCoder.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: "priv/repo/code_graph.db",
  pool_size: 10,
  load_extensions: [
    SqliteVss.loadable_path_vector0() <> ".so",
    SqliteVss.loadable_path_vss0() <> ".so"
  ]

# External ML Bridge Configuration
config :procoder, :ml_bridge,
  base_url: "http://localhost:5000"

# RateLimiter Configuration (Token Bucket)
config :procoder, ProCoder.Brain.RateLimiter,
  tokens_per_second: 5,
  bucket_capacity: 20

# Disable Logger truncation for extreme visibility
config :logger, :console, truncate: :infinity

# Import environment specific config. This must remain at the bottom
import_config "#{Mix.env()}.exs"
