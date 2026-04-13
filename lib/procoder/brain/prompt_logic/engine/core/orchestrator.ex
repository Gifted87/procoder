defmodule ProCoder.Brain.PromptLogic.Engine.Core.Orchestrator do
  @moduledoc """
  The central cognitive hub of the ProCoder brain subsystem.

  Implements a stateless transformation pipeline to convert heterogeneous input
  data into high-salience, security-hardened message arrays for LLM ingestion.
  """

  require Logger
  alias ProCoder.Brain.PromptEngine.SalienceRanker
  alias ProCoder.Brain.PromptLogic.Engine.Formatter
  alias ProCoder.Brain.PromptEngine.Corrector
  alias ProCoder.Core.Types.Message
  alias ProCoder.Brain.Client.Telemetry.EventMonitor

  @doc """
  Orchestrates the transformation pipeline.
  Takes a list of raw context segments and transforms them into a message array.
  """
  @spec orchestrate(list(map())) :: {:ok, list(Message.t())} | {:error, term()}
  def orchestrate(raw_segments) do
    start_time = System.monotonic_time(:millisecond)

    try do
      # 1. Gradient of Precision Pipeline
      result =
        raw_segments
        |> rank_segments()
        |> format_messages()
        |> normalize_messages()
        |> truncate_to_budget()

      # 2. Telemetry
      duration = System.monotonic_time(:millisecond) - start_time
      EventMonitor.emit([:procoder, :prompt_engine, :orchestration, :success], %{duration_ms: duration}, %{segments_count: length(raw_segments)})

      {:ok, result}
    rescue
      e ->
        Logger.error("Orchestration pipeline failed: #{Exception.message(e)}")
        EventMonitor.emit([:procoder, :prompt_engine, :orchestration, :failure], %{count: 1}, %{error: Exception.message(e)})
        {:error, :orchestration_failed}
    end
  end

  # --- Internal Pipeline Stages ---

  defp rank_segments(segments) do
    if approximate_tokens(segments) > 800_000 do
      Logger.info("[Orchestrator] Context > 800k tokens detected. Activating SalienceRanker.")
      try do
        SalienceRanker.rank(segments)
      rescue
        e ->
          Logger.warn("SalienceRanker failed, proceeding with unsorted context: #{inspect(e)}")
          segments
      end
    else
      # If under 200k tokens, preserve Exact Lossless Memory by bypassing the ranker.
      segments
    end
  end

  defp approximate_tokens(segments) do
    # Conservative token estimation for code-heavy contexts (~3 bytes == 1 token)
    bytes = Enum.reduce(segments, 0, fn segment, acc ->
      content_size = 
        cond do
          is_map(segment) and not is_struct(segment) and Map.has_key?(segment, :parts) ->
            # Sum up byte sizes of all primitive parts (text, args, output)
            # instead of using inspect/1 which is noisy.
            Enum.reduce(segment[:parts] || [], 0, fn
              %{"text" => t}, sub_acc -> sub_acc + byte_size(t)
              %{"thought" => t}, sub_acc -> sub_acc + byte_size(t)
              %{"functionCall" => %{"args" => args}}, sub_acc -> 
                sub_acc + byte_size(Jason.encode!(args))
              %{"functionResponse" => %{"response" => resp}}, sub_acc ->
                sub_acc + byte_size(Jason.encode!(resp))
              _, sub_acc -> sub_acc
            end)

          is_struct(segment) ->
            byte_size(segment.content || "")

          true ->
            byte_size(Map.get(segment, :content, "") || "")
        end
        
      acc + content_size
    end)
    
    div(bytes, 3)
  end

  defp format_messages(segments) do
    Enum.map(segments, fn segment ->
      # If it's already a native Gemini turn (has :parts), pass it through but ensure
      # it has a :timestamp for the downstream sorting step.
      if is_map(segment) and not is_struct(segment) and Map.has_key?(segment, :parts) do
        Map.put_new(segment, :timestamp, DateTime.utc_now())
      else
        %Message{
          role: Map.get(segment, :role, :user),
          content: Formatter.redact(Map.get(segment, :content, "")),
          salience_score: Map.get(segment, :salience_score, 0.0),
          timestamp: Map.get(segment, :timestamp) || DateTime.utc_now()
        }
      end
    end)
  end

  defp normalize_messages(messages) do
    {system_msgs, other_msgs} = Enum.split_with(messages, &(&1.role == :system))

    # Restore chronological order for history/context messages (Stable Sort)
    sorted_history = Enum.sort_by(other_msgs, fn msg -> 
      if is_struct(msg), do: msg.timestamp, else: Map.get(msg, :timestamp, DateTime.utc_now())
    end, {:asc, DateTime})

    system_msgs ++ sorted_history
  end

  @hard_token_limit 800_000

  defp truncate_to_budget(messages) do
    current_tokens = approximate_tokens(messages)
    
    if current_tokens > @hard_token_limit do
      Logger.warn("[Orchestrator] Hard token limit reached (#{current_tokens}). Truncating lowest-salience segments.")
      # Distinguish between system and other messages for safe truncation
      {system_msgs, other_msgs} = Enum.split_with(messages, &(&1.role == :system))
      
      # Sort OTHER messages by salience (ascending) so we drop lowest first
      # NOTE: This temporary sort is just for truncation selection.
      sorted_for_drop = Enum.sort_by(other_msgs, fn msg -> Map.get(msg, :salience_score, 0.0) end, :asc)
      
      pruned_history = drop_until_under_budget(sorted_for_drop, current_tokens - @hard_token_limit)
      
      # Restore original chronological order for the remaining messages
      # by re-sorting by timestamp.
      final_history = Enum.sort_by(pruned_history, fn msg -> msg.timestamp end, {:asc, DateTime})
      system_msgs ++ final_history
    else
      messages
    end
  end

  defp drop_until_under_budget(msgs, amount_to_drop) when amount_to_drop <= 0, do: msgs
  defp drop_until_under_budget([], _), do: []
  defp drop_until_under_budget([msg | rest], amount_to_drop) do
    tokens = approximate_tokens([msg])
    drop_until_under_budget(rest, amount_to_drop - tokens)
  end

  @doc """
  Handles one-shot error correction for tool calls.
  Designed for use as a feedback-loop entry point in the Actuator layer.
  """
  @spec correct_tool_call(String.t(), map(), integer()) :: {:ok, map()} | {:retry, String.t()}
  def correct_tool_call(raw_json, schema, retry_count \\ 0) do
    case Corrector.correct_tool_call(raw_json, schema, retry_count) do
      {:ok, parsed} -> {:ok, parsed}
      {:retry, feedback} -> {:retry, feedback}
      {:error, _reason} -> {:retry, "Unrecoverable tool call error"}
    end
  end
end
