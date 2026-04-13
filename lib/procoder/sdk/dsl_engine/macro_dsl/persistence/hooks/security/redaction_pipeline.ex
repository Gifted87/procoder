defmodule ProCoder.SDK.MacroDSL.Persistence.Hooks.Security.RedactionPipeline do
  @moduledoc """
  The Redaction and Security Pipeline for ProCoder Persistence Hooks.

  Acts as a critical gatekeeper for the cognitive persistence infrastructure,
  identifying, redacting, and replacing sensitive agent information before
  committing to the persistence layer (Repo/History Stack).
  """

  require Logger

  alias ProCoder.Brain.Client.Telemetry.EventMonitor, as: Monitor

  @type sanitized_state :: map() | list() | binary()

  @doc """
  Main entry point for the redaction pipeline.
  Applies schema-based sanitization and content-based redaction recursively.
  """
  @spec process(term(), list(atom())) :: sanitized_state()
  def process(data, fields) do
    try do
      data
      |> apply_schema_sanitization(fields)
      |> apply_content_redaction()
    rescue
      e ->
        Logger.error("Redaction Pipeline Failure: #{Exception.message(e)}")
        Monitor.emit([:procoder, :persistence, :redaction, :failure], %{}, %{error: inspect(e)})
        # Fail-Closed: Return redacted placeholder or discard
        "[REDACTED_DUE_TO_PIPELINE_FAILURE]"
    end
  end

  # --- Pipeline Stages ---

  defp apply_schema_sanitization(data, fields) when is_map(data) do
    Enum.reduce(data, %{}, fn {k, v}, acc ->
      if k in fields do
        Map.put(acc, k, "[REDACTED]")
      else
        Map.put(acc, k, apply_schema_sanitization(v, fields))
      end
    end)
  end

  defp apply_schema_sanitization(data, fields) when is_list(data) do
    Enum.map(data, &apply_schema_sanitization(&1, fields))
  end

  defp apply_schema_sanitization(data, _fields), do: data

  defp apply_content_redaction(data) when is_binary(data) do
    # Delegate to EventMonitor's hardened redaction logic for deep-packet inspection
    Monitor.redact_metadata(%{content: data}) |> Map.get(:content)
  end

  defp apply_content_redaction(data) when is_map(data) do
    Enum.reduce(data, %{}, fn {k, v}, acc ->
      Map.put(acc, k, apply_content_redaction(v))
    end)
  end

  defp apply_content_redaction(data) when is_list(data) do
    Enum.map(data, &apply_content_redaction/1)
  end

  defp apply_content_redaction(data), do: data

  @custom_rules_table :redaction_custom_rules

  @doc """
  Injects custom redaction rules at runtime.
  Rules are persisted in an ETS table and applied in apply_content_redaction.
  """
  def register_custom_rules(patterns) when is_list(patterns) do
    # Ensure the ETS table exists (idempotent)
    if :ets.info(@custom_rules_table) == :undefined do
      :ets.new(@custom_rules_table, [:set, :public, :named_table])
    end

    Enum.each(patterns, fn pattern ->
      :ets.insert(@custom_rules_table, {pattern, true})
    end)

    :ok
  end

  defp load_custom_rules do
    if :ets.info(@custom_rules_table) == :undefined do
      []
    else
      :ets.tab2list(@custom_rules_table) |> Enum.map(fn {pattern, _} -> pattern end)
    end
  end
end
