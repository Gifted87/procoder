defmodule ProCoder.Brain.RateLimiter do
  @moduledoc """
  High-performance token bucket rate limiter for ProCoder LLM API interactions.
  Utilizes ETS for atomic, lock-free access to bucket state across the agent swarm.
  """
  use GenServer
  require Logger

  @table_name :rate_limiter_state
  @refill_interval_ms 100

  defstruct tokens: 0, last_refill_timestamp: 0

  # --- Client API ---

  @doc """
  Consumes a specified number of tokens from the bucket.
  If tokens are unavailable, blocks for the calculated duration before retrying.
  """
  def consume(count \\ 1) do
    case try_consume(count) do
      {:ok, _tokens} ->
        :ok

      {:wait, ms} ->
        # Add jitter to avoid thundering herd problem
        jitter = :rand.uniform(50)
        Process.sleep(ms + jitter)
        consume(count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_consume(count) do
    config = Application.get_env(:procoder, ProCoder.Brain.RateLimiter, [])
    capacity = Keyword.get(config, :bucket_capacity, 100)
    tps = Keyword.get(config, :tokens_per_second, 25)

    case :ets.lookup(@table_name, :bucket) do
      [{:bucket, state}] ->
        now = System.system_time(:millisecond)
        elapsed = (now - state.last_refill_timestamp) / 1000
        refill = elapsed * tps
        tokens = min(capacity, state.tokens + refill)

        if tokens >= count do
          new_state = %{state | tokens: tokens - count, last_refill_timestamp: now}
          :ets.insert(@table_name, {:bucket, new_state})
          {:ok, tokens - count}
        else
          needed = count - tokens
          wait_ms = round((needed / tps) * 1000)
          {:wait, wait_ms}
        end

      [] ->
        {:error, :uninitialized}
    end
  end

  # --- GenServer Callbacks ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_) do
    config = Application.get_env(:procoder, ProCoder.Brain.RateLimiter, [])
    capacity = Keyword.get(config, :bucket_capacity, 100)

    :ets.new(@table_name, [:named_table, :public, read_concurrency: true])
    :ets.insert(@table_name, {:bucket, %__MODULE__{tokens: capacity, last_refill_timestamp: System.system_time(:millisecond)}})

    schedule_refill()
    {:ok, %{tps: Keyword.get(config, :tokens_per_second, 25), capacity: capacity}}
  end

  @impl true
  def handle_info(:refill, state) do
    refill_bucket(state.tps, state.capacity)
    schedule_refill()
    {:noreply, state}
  end

  # --- Internal Logic ---

  defp refill_bucket(tps, capacity) do
    case :ets.lookup(@table_name, :bucket) do
      [{:bucket, old_state}] ->
        now = System.system_time(:millisecond)
        elapsed = (now - old_state.last_refill_timestamp) / 1000
        new_tokens = min(capacity, old_state.tokens + (elapsed * tps))
        
        :ets.insert(@table_name, {:bucket, %{old_state | tokens: new_tokens, last_refill_timestamp: now}})
      [] ->
        :ok
    end
  end

  defp schedule_refill do
    Process.send_after(self(), :refill, @refill_interval_ms)
  end
end
