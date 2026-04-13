import Config

# ProCoder Production Configuration Module
# This module acts as the orchestration layer for production environment hardening.
# It leverages BEAM introspection to dynamically scale resources based on hardware topology.

scheduler_count = System.schedulers_online()

# 1. High-Concurrency Scaling: SessionManager
# Scale worker count by factor of 10 relative to schedulers to handle autonomous tasks.
config :procoder, ProCoder.SessionManager,
  max_workers: scheduler_count * 10

# 2. Resilient Connectivity: Finch HTTP Pool
# Scale connection pool size to twice the count of online schedulers for high-frequency streaming.
config :procoder, ProCoder.Brain.Client,
  pool_size: scheduler_count * 2

# 3. Bandwidth Management: RateLimiter
# Granular control via runtime variables for cost-budget and API SLA management.
# Defaults are defined to ensure safe operation if environment variables are missing.
config :procoder, ProCoder.Brain.RateLimiter,
  tokens_per_second: String.to_integer(System.get_env("RATE_LIMIT_TPS", "25")),
  bucket_capacity: String.to_integer(System.get_env("RATE_LIMIT_CAPACITY", "100"))

# 4. Mandatory Runtime Validation
# Ensure required production secrets are present. The system will fail-fast at boot if missing.
if is_nil(System.get_env("PROCODER_LLM_API_KEY")) do
  raise "PROCODER_LLM_API_KEY must be set in the production environment."
end

# 5. Production Observability
# Enable granular telemetry for root-cause analysis based on environment toggle.
config :procoder, :telemetry,
  debug_mode: System.get_env("DEBUG_MODE", "false") == "true"
