import Config

# ProCoder Development Configuration
# This file is used for local development, providing observability,
# resource-constrained execution, and sandbox isolation.

# 1. Observability: Enable Verbose Debugging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  level: :debug

config :procoder, :telemetry,
  debug_mode: true,
  log_path: Path.expand("tmp/logs/procoder_dev.log", File.cwd!())

# 2. Localized Resource Management: Static/Low-Overhead Scaling
config :procoder, ProCoder.SessionManager,
  max_workers: 10,
  worktree_root: Path.expand("tmp/worktrees", File.cwd!())

config :procoder, ProCoder.Brain.Client,
  pool_size: 5,
  max_overflow: 2

# 3. Sandbox and Pathing: Non-destructive local paths
config :procoder, ProCoder.Repo,
  database: Path.expand("tmp/repo/code_graph_dev.db", File.cwd!())

# 4. Mocking Infrastructure: Ensure idempotency
# We route to a local mock adapter to avoid external network dependencies
config :procoder, ProCoder.Brain.Client,
  adapter: ProCoder.Brain.Adapters.Mock,
  mock_latency_ms: 100

# 5. Runtime Initialization: Ensure directories exist
# We use a deferred execution block to ensure directories are created 
# during the application configuration phase, without violating 
# the read-only requirement of the config after startup.
[
  "tmp/worktrees",
  "tmp/repo",
  "tmp/logs"
]
|> Enum.each(fn path ->
  full_path = Path.expand(path, File.cwd!())
  unless File.exists?(full_path) do
    File.mkdir_p!(full_path)
  end
end)
