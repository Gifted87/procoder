defmodule ProCoder.Brain.MemoryStore.Config do
  @moduledoc """
  Configuration interface for the ProCoder Brain Memory Subsystem.

  Provides a centralized, type-safe way to access memory subsystem parameters
  defined in the application environment. These values are injected at runtime
  by `ProCoder.Config.RuntimeInitializer`.
  """

  @doc """
  Returns the duration in seconds after which log segments are considered stale.
  """
  def memory_ttl_seconds do
    Application.get_env(:procoder, :memory_subsystem)[:memory_ttl_seconds] || 3600
  end

  @doc """
  Returns the frequency in milliseconds for the Compactor background task cycle.
  """
  def compaction_interval_ms do
    Application.get_env(:procoder, :memory_subsystem)[:compaction_interval_ms] || 60_000
  end

  @doc """
  Returns the hard limit on ETS table size in bytes per Agent process.
  """
  def max_memory_per_session do
    Application.get_env(:procoder, :memory_subsystem)[:max_memory_per_session] || 1024 * 1024 * 50
  end

  @doc """
  Returns the number of logs to group before invoking the Summarizer.
  """
  def summary_batch_size do
    Application.get_env(:procoder, :memory_subsystem)[:summary_batch_size] || 20
  end

  @doc """
  Returns the configuration for the Summarizer worker pool.
  """
  def summarizer_pool_size do
    Application.get_env(:procoder, :memory_subsystem)[:summarizer_pool_size] || System.schedulers_online()
  end
end
