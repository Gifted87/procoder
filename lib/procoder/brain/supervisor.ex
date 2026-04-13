defmodule ProCoder.Brain.Supervisor do
  @moduledoc """
  The `ProCoder.Brain.Supervisor` is the domain supervisor for the Brain Subsystem.
  It governs the lifecycle of the LLM connection pool, prompt engineering,
  memory persistence, and rate limiting.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # ConnectionPool (Finch)
      {Finch, name: :procoder_finch, pools: %{
        :default => [size: 50]
      }},

      # RateLimiter
      {ProCoder.Brain.RateLimiter, []},

      # MemoryStore manages session-specific cognitive persistence.
      {ProCoder.Brain.MemoryStore.Supervisor, []},

      # LLM Client Engine handles external network interactions.
      {ProCoder.Brain.Client.Engine, []},

      # Bumblebee Embedding Generation Worker
      {ProCoder.Brain.ClientEngine.EmbeddingWorker, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
