defmodule ProCoder.Brain.MemoryStore.Supervisor do
  @moduledoc """
  The supervisor for the ProCoder Brain memory subsystem.
  
  Manages the lifecycle of core memory components:
  - CacheEngine: Volatile session memory storage (ETS).
  - Compactor: TTL-based memory maintenance and distillation.
  - Summarizer: Semantic log summarization and redaction engine.
  
  Utilizes a :one_for_one restart strategy to ensure granular recovery of independent
  memory services while maintaining system-wide stability.
  """

  use Supervisor
  require Logger

  alias ProCoder.Brain.MemoryStore.{Compactor, Summarizer}

  @doc """
  Starts the memory subsystem supervisor.
  """
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # The Summarizer handles cognitive distillation and must be active
      # to receive compaction tasks.
      {Summarizer, []},
      
      # The Compactor orchestrates memory maintenance. It is supervised 
      # separately so that logic failures in compaction don't impact 
      # the summarization service.
      {Compactor, []}
    ]

    # :one_for_one ensures that if a child crashes (e.g., due to unexpected state),
    # it is restarted without affecting its siblings.
    # We define reasonable restart intensity limits to prevent resource exhaustion
    # during rapid failure loops.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
