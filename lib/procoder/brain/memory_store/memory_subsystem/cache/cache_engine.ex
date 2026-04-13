defmodule ProCoder.Brain.MemoryStore.Cache.CacheEngine do
  @moduledoc """
  The CacheEngine provides a high-performance, volatile, and isolated ETS-backed
  memory repository for autonomous agent sessions.

  Each agent session is assigned a dedicated ETS table, ensuring process isolation,
  high throughput, and sub-millisecond retrieval of cognitive state.
  """

  use GenServer
  require Logger

  alias ProCoder.Brain.MemoryStore.Config

  @type session_id :: String.t()
  @type key :: term()
  @type value :: term()

  @doc """
  Starts a new CacheEngine for a given session.
  """
  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @impl true
  def init(session_id) do
    # Initialize the ETS table for this specific session.
    # We use ordered_set for history-based memory (sorting by timestamp/key)
    table = :ets.new(:"cache_#{session_id}", [:ordered_set, :protected, :named_table])
    
    {:ok, %{
      session_id: session_id,
      table: table,
      stats: %{cache_hit: 0, cache_miss: 0, bytes_used: 0}
    }}
  end

  @doc """
  Writes a value to the session cache. Validates payload size against configuration.
  """
  def write_memory(session_id, key, value) do
    GenServer.call(via_tuple(session_id), {:put, key, value})
  end

  @doc """
  Reads a value from the session cache.
  """
  def read_memory(session_id, key) do
    GenServer.call(via_tuple(session_id), {:get, key})
  end

  @doc """
  Clears the entire session cache upon termination.
  """
  def clear_session(session_id) do
    GenServer.call(via_tuple(session_id), :clear)
  end

  @impl true
  def handle_call({:put, key, value}, _from, %{table: table, stats: stats} = state) do
    # Check memory limit
    if current_memory_usage(table) >= Config.max_memory_per_session() do
      {:reply, {:error, :memory_limit_reached}, state}
    else
      # Atomic write
      try do
        :ets.insert(table, {key, value, DateTime.utc_now()})
        {:reply, :ok, %{state | stats: %{stats | bytes_used: current_memory_usage(table)}}}
      rescue
        _e -> {:reply, {:error, :invalid_payload}, state}
      end
    end
  end

  @impl true
  def handle_call({:get, key}, _from, %{table: table, stats: stats} = state) do
    case :ets.lookup(table, key) do
      [{^key, value, _timestamp}] ->
        {:reply, {:ok, value}, %{state | stats: %{stats | cache_hit: stats.cache_hit + 1}}}
      [] ->
        {:reply, {:error, :not_found}, %{state | stats: %{stats | cache_miss: stats.cache_miss + 1}}}
    end
  end

  @impl true
  def handle_call(:clear, _from, %{table: table} = state) do
    :ets.delete(table)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def terminate(_reason, %{table: table, session_id: session_id}) do
    # Flush all hot-cache entries to the DB for durability before shutdown
    try do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
      :ets.tab2list(table)
      |> Enum.each(fn {key, value, _ts} ->
        blob = :erlang.term_to_binary({key, value})
        hash = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
        ProCoder.Repo.query(
          "INSERT OR REPLACE INTO snapshots (id, snapshot_id, session_id, memory_blob, integrity_hash, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [Ecto.UUID.generate(), Ecto.UUID.generate(), session_id, blob, hash, now, now]
        )
      end)
    rescue
      e -> Logger.warning("[CacheEngine] flush on terminate failed: #{Exception.message(e)}")
    end
    :ok
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "cache_#{session_id}"}}

  defp current_memory_usage(table) do
    :ets.info(table, :memory) * :erlang.system_info(:wordsize)
  end
end
