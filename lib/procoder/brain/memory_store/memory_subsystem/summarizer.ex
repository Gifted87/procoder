defmodule ProCoder.Brain.MemoryStore.Summarizer do
  @moduledoc """
  The cognitive distillation engine for the ProCoder memory subsystem.
  Handles redaction, semantic summarization, and cognitive snapshot generation.
  """

  use GenServer
  require Logger

  alias ProCoder.Brain.MemoryStore.Types.{CognitiveSnapshot, MemorySegment}
  alias ProCoder.Brain.Client.Engine, as: LLMClient

  @type state :: %{
    active_tasks: map(),
    redaction_patterns: list(Regex.t())
  }

  @doc """
  Starts the Summarizer GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Orchestrates the fetch, redact, and distill workflow.
  """
  @spec summarize_segment(binary()) :: :ok
  def summarize_segment(segment_id) do
    GenServer.cast(__MODULE__, {:summarize, segment_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{
      active_tasks: %{},
      redaction_patterns: [
        ~r/(?:AIza[0-9A-Za-z-_]{35})/,
        ~r/(?:sk-(?:live|test)_[a-zA-Z0-9]{32})/,
        ~r/PROCODER_LLM_API_KEY=\S+/,
        ~r/OPENAI_API_KEY=\S+/
      ]
    }}
  end

  @impl true
  def handle_cast({:summarize, segment_id}, state) do
    case fetch_segment(segment_id) do
      {:ok, %MemorySegment{} = segment} ->
        sanitized_log = handle_redaction(segment.summary, state.redaction_patterns)
        
        Task.start(fn ->
          case dispatch_llm_request(sanitized_log) do
            {:ok, summary} ->
              finalize_snapshot(segment, summary)
            {:error, reason} ->
              Logger.error("Summarization failed for #{segment_id}: #{inspect(reason)}")
              handle_degradation(segment)
          end
        end)
        
        {:noreply, %{state | active_tasks: Map.put(state.active_tasks, segment_id, :in_progress)}}
        
      _ ->
        {:noreply, state}
    end
  end

  @doc """
  Private utility for pattern-based and heuristic redaction.
  """
  def handle_redaction(raw_log, patterns) do
    Enum.reduce(patterns, raw_log, fn pattern, acc ->
      String.replace(acc, pattern, "REDACTED_SECRET")
    end)
  end

  @doc """
  Summarizes raw content string for context compaction.
  """
  def summarize_content(content) do
    # For now, heuristic distillation + truncation
    "SUMMARY: " <> String.slice(content, 0, 100) <> "..."
  end

  # --- Internal Logic ---
  @doc """
  Internal bridge to the LLM client.
  """
  def dispatch_llm_request(content) do
    # Using LLMClient for summarization as per system specification
    LLMClient.chat([%{role: :user, content: "Summarize the following interaction history concisely: #{content}"}])
  end

  defp finalize_snapshot(segment, summary) do
    snapshot = %CognitiveSnapshot{
      snapshot_id: Ecto.UUID.generate(),
      agent_id: "procoder_agent",
      state_data: %{source_segment: segment.segment_id, summary: summary}
    }
    
    # Broadcast to persistence layer or update ETS state
    Logger.info("Snapshot finalized: #{snapshot.snapshot_id}")
    :ok
  end

  defp handle_degradation(segment) do
    keyword_summary = "Keywords: " <> String.slice(segment.summary, 0, 100)
    finalize_snapshot(segment, keyword_summary)
  end

  defp fetch_segment(segment_id) do
    # Try the ETS hot cache first (table named :memory_segments)
    table = :memory_segments
    case :ets.info(table) do
      :undefined ->
        # Table not yet created, fall back to DB
        fetch_segment_from_db(segment_id)
      _ ->
        case :ets.lookup(table, segment_id) do
          [{^segment_id, segment}] -> {:ok, segment}
          [] -> fetch_segment_from_db(segment_id)
        end
    end
  end

  defp fetch_segment_from_db(segment_id) do
    import Ecto.Query
    alias ProCoder.Brain.MemoryStore.Types.MemorySegment
    # Attempt to load from the persisted store
    case ProCoder.Repo.query(
      "SELECT segment_id, summary FROM memory_segments WHERE segment_id = ? LIMIT 1",
      [segment_id]
    ) do
      {:ok, %{rows: [[id, summary]]}} ->
        {:ok, %MemorySegment{segment_id: id, summary: summary}}
      _ ->
        {:error, :not_found}
    end
  end
end
