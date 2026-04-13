import Config

# ProCoder Test Configuration
# This file provides a deterministic, isolated, and mock-based environment
# for running the system test suite.

# 1. Mocking Infrastructure
# Replace external Brain Client with a local Mock implementation.
config :procoder, ProCoder.Brain.Client,
  module: ProCoder.Brain.MockClient,
  pool_size: 5,
  max_overflow: 0

# Planner mock configuration to allow DAG assertion
config :procoder, ProCoder.Brain.Planner,
  agent_module: ProCoder.Brain.MockAgent,
  record_execution: true

# 2. Persistence Layer
# Use in-memory SQLite database to ensure clean state per test case.
config :procoder, ProCoder.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox

# 3. Component Hardening for Testing
# Set RateLimiter to noop mode to avoid timing-based flakiness.
config :procoder, ProCoder.Brain.RateLimiter,
  module: ProCoder.Brain.NoOpRateLimiter,
  tokens_per_second: 1000,
  bucket_capacity: 1000

# Set SessionManager to single-process mode for deterministic concurrency.
config :procoder, ProCoder.SessionManager,
  max_workers: 1,
  worktree_root: "/tmp/procoder/test/worktrees"

# 4. Security and Isolation
# Force-disable API usage by ensuring key is missing or dummy.
config :procoder, :security,
  enforce_no_api_key: true

# 5. Fault-Tolerance & Failure Simulation
# Inject Failure Simulator hooks for testing resilience.
config :procoder, :failure_simulator,
  enabled: true,
  crash_probability: 0.0,
  simulate_timeouts: false

# ExUnit Configuration
config :ex_unit,
  capture_log: true,
  assert_receive_timeout: 1000
