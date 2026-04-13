defmodule ProCoder.Config.RuntimeInitializer do
  @moduledoc """
  The high-integrity orchestration point for the ProCoder application bootstrap cycle.
  
  This module implements the runtime configuration logic for dynamic environment 
  variable injection, secret validation, and system-level integrity checks 
  ensuring secure initialization of the OTP supervision tree.
  """

  require Logger

  @doc """
  Initializes the runtime environment configuration.
  
  This function should be invoked during the application boot phase. It performs:
  1. Dynamic scaling calculation based on scheduler count.
  2. Secret injection via system environment variables.
  3. System invariant and filesystem validation.
  4. Application-wide configuration injection.
  """
  def init_runtime_config! do
    scheduler_count = System.schedulers_online()
    env = System.get_env("MIX_ENV", "dev") |> String.to_existing_atom()

    validate_environment_secrets!(env)
    
    # Configure dynamic resources
    configure_session_manager(scheduler_count)
    configure_http_pools(scheduler_count)
    configure_rate_limiter()

    # Integrity check
    ProCoder.Config.Validator.validate_environment!()

    :ok
  end

  defp validate_environment_secrets!(env) when env == :prod do
    # Ensure mandatory secrets exist
    _ = System.fetch_env!("PROCODER_LLM_API_KEY")
    :ok
  end

  defp validate_environment_secrets!(_), do: :ok

  defp configure_session_manager(scheduler_count) do
    max_workers = scheduler_count * 10
    worktree_root = System.get_env("WORKTREE_ROOT", "/tmp/procoder/worktrees")
    
    Application.put_env(:procoder, ProCoder.SessionManager, [
      max_workers: max_workers,
      worktree_root: worktree_root
    ])
  end

  defp configure_http_pools(scheduler_count) do
    pool_size = scheduler_count * 2
    
    Application.put_env(:procoder, ProCoder.Brain.Client, [
      pool_size: pool_size,
      max_overflow: 5
    ])
  end

  defp configure_rate_limiter do
    tps = String.to_integer(System.get_env("RATE_LIMIT_TPS", "25"))
    capacity = String.to_integer(System.get_env("RATE_LIMIT_CAPACITY", "100"))

    Application.put_env(:procoder, ProCoder.Brain.RateLimiter, [
      tokens_per_second: tps,
      bucket_capacity: capacity
    ])
  end
end
