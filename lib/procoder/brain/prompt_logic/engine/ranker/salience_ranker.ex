defmodule ProCoder.Brain.PromptEngine.SalienceRanker do
  @moduledoc """
  The SalienceRanker acts as the critical cognitive filter for the ProCoder PromptEngine.
  It ranks, weights, and prunes raw context components based on a 'gradient of precision'
  algorithm to ensure high-salience message arrays for LLM ingestion.
  """

  require Logger

  @sliding_window_size 10

  @doc """
  Ranks a list of context segments based on their salience score.
  Segments within the sliding window (most recent 10) are always preserved.
  Others below the threshold (0.6) are pruned.
  Returns a sorted list of segments in descending order of salience.
  """
  @spec rank(list(map())) :: list(map())
  def rank(segments) when is_list(segments) do
    try do
      # 1. Identify sliding window (most recent turns)
      {window, candidates} = split_sliding_window(segments)

      # 2. Rank and prune candidates
      processed_candidates =
        candidates
        |> Enum.map(&calculate_salience/1)
        |> prune_low_salience()

      # 3. Always preserve window (but still calculate salience for sorting)
      processed_window = Enum.map(window, &calculate_salience/1)

      (processed_window ++ processed_candidates)
      |> Enum.sort_by(fn segment -> segment[:salience_score] end, :desc)
      |> emit_telemetry()
    rescue
      e ->
        Logger.error("SalienceRanker failure: #{inspect(e)}")
        segments # Fallback to original instead of empty
    end
  end

  defp split_sliding_window(segments) do
    # Sort by timestamp DESC to find most recent
    sorted = Enum.sort_by(segments, fn s -> s[:timestamp] || DateTime.utc_now() end, {:desc, DateTime})
    {window, candidates} = Enum.split(sorted, @sliding_window_size)
    {window, candidates}
  end

  # --- Internal Logic ---

  # Blueprint Formula: S = (W_recency * R) + (W_relevance * V) + (W_dependency * D)
  defp calculate_salience(segment) do
    # Respect pre-calculated or forced scores (e.g., from AgentFSM)
    # Also ensure :system role always has a base high salience
    base_score = if segment[:role] == :system, do: 0.9, else: 0.0
    manual_score = Map.get(segment, :salience_score)

    w_recency = 0.5
    w_relevance = 1.0
    w_dependency = 0.8

    r = Map.get(segment, :recency, 0.0)
    v = Map.get(segment, :relevance, 0.0)
    d = Map.get(segment, :dependency, 0.0)

    calculated_score = (w_recency * r) + (w_relevance * v) + (w_dependency * d)

    # Union logic: Highest of (calculated, manual, or role-based)
    final_score = Enum.max([calculated_score, manual_score || 0.0, base_score])

    Map.put(segment, :salience_score, final_score)
  end

  defp prune_low_salience(segments) do
    # Prune anything below 0.6 unless it's a system message.
    # System messages are already boosted to 0.9, but this is an extra safety.
    Enum.filter(segments, fn s ->
      s.role == :system or Map.get(s, :salience_score, 0.0) >= 0.6
    end)
  end

  defp emit_telemetry(ranked_segments) do
    :telemetry.execute(
      [:procoder, :prompt_engine, :salience, :evaluated],
      %{count: length(ranked_segments)},
      %{timestamp: DateTime.utc_now()}
    )
    ranked_segments
  end
end
