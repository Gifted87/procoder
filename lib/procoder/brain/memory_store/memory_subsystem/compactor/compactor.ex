defmodule ProCoder.Brain.MemoryStore.Compactor do
  @moduledoc """
  The Compactor GenServer manages TTL-based memory cleanup and summarization orchestration
  within the ProCoder brain subsystem. It monitors session memory tables and dispatches
  stale segments to the Summarizer.
  """

  use GenServer
  require Logger

  alias ProCoder.Brain.MemoryStore.Config
  alias ProCoder.Brain.MemoryStore.Summarizer

  @doc """
  Starts the Compactor GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forcefully triggers a compaction cycle.
  """
  def force_gc do
    send(__MODULE__, :heartbeat)
  end

  @impl true
  def init(_opts) do
    # Schedule initial heartbeat
    :timer.send_interval(Config.compaction_interval_ms(), :heartbeat)

    {:ok, %{
      last_check: DateTime.utc_now()
    }}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    :telemetry.execute([:procoder, :memory, :compaction, :started], %{timestamp: DateTime.utc_now()})

    try do
      if mem_pressure_high?() do
        Logger.warn("High memory pressure detected, accelerating compaction cycle.")
      end

      run_compaction_cycle()
    rescue
      e ->
        Logger.error("Compaction cycle failed: #{inspect(e)}")
        :telemetry.execute([:procoder, :memory, :compaction, :error], %{reason: inspect(e)})
    end

    :telemetry.execute([:procoder, :memory, :compaction, :finished], %{timestamp: DateTime.utc_now()})
    {:noreply, state}
  end

  # --- Internal Logic ---

  defp run_compaction_cycle do
    # Discovery: Identify active session tables via Registry
    Registry.select(ProCoder.Registry, [{{{:via, Registry, {ProCoder.Registry, :"$1"}}, :_, :_}, [], [:"$1"]}])
    |> Enum.filter(fn name -> is_binary(name) and String.starts_with?(name, "cache_") end)
    |> Enum.each(fn session_id ->
      table_name = String.to_existing_atom(session_id)
      process_table_tokens(table_name)
    end)
  end

  # Blueprint Logic: 
  # T_available = T_max - (T_system + T_output_reserve)
  # If T_current > 0.9 * T_available: Summarize and Evict.
  defp process_table_tokens(table) do
    max_tokens = 200_000 # Default for Sonnet
    t_available = max_tokens - 10_000 # Reservation
    
    messages = :ets.tab2list(table)
    t_current = Enum.reduce(messages, 0, fn {_key, val, _ts}, acc -> acc + estimate_tokens(val) end)

    if t_current > 0.9 * t_available do
      Logger.info("Context pressure on #{table}: #{t_current} tokens. Compacting...")
      compact_messages(table, messages)
    end
  end

  defp compact_messages(table, messages) do
    # Preservation Rule: System Prompt, PROCODER.md, and last 3 turns
    # We'll assume the list is sorted or we sorts it by timestamp
    sorted = Enum.sort_by(messages, fn {_key, _val, ts} -> ts end, :desc)
    
    # Identify candidates for summarization (Tool outputs older than 3 turns)
    to_summarize = sorted 
                   |> Enum.drop(6) # Last 3 turns = 3 user + 3 assistant/tool messages approximately
                   |> Enum.filter(fn {_key, val, _ts} -> is_tool_output?(val) end)

    Enum.each(to_summarize, fn {key, val, _ts} ->
      summary = Summarizer.summarize_content(val)
      :ets.insert(table, {key, summary, DateTime.utc_now()})
    end)
  end

  defp estimate_tokens(content) when is_binary(content), do: round(String.length(content) / 4)
  defp estimate_tokens(_), do: 0

  defp is_tool_output?(content) do
    String.contains?(content, "<tool_output>") or String.contains?(content, "Output of")
  end

  defp mem_pressure_high? do
    # Check :memsup (OTP system)
    case :memsup.get_system_memory_data() do
      list when is_list(list) ->
        total = Keyword.get(list, :total_memory)
        used = Keyword.get(list, :used_memory)
        if total && used, do: (used / total) > 0.85, else: false
      _ -> false
    end
  end
end
