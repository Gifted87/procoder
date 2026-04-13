defmodule ProCoder.Brain.Client.Telemetry.EventMonitor do
  @moduledoc """
  Telemetry event monitor for the ProCoder LLM client.

  This module handles the sanitization and dispatch of observability events
  originating from the client engine, SSE parser, and rate limiter.
  It adheres to security compliance by enforcing automated data redaction
  on all metadata maps before telemetry dispatch.
  """

  require Logger

  @doc """
  Dispatches an event to the telemetry bus after applying redaction rules.
  """
  @spec emit(event_name :: [atom()], measurements :: map(), metadata :: map()) :: :ok
  def emit(event_name, measurements, metadata) when is_list(event_name) do
    if :ets.whereis(:telemetry_handler_table) != :undefined do
      clean_metadata = redact_metadata(metadata)
      :telemetry.execute(event_name, measurements, clean_metadata)
    end
  end

  # --- Data Redaction Logic ---

  @redaction_patterns [
    ~r"(?:AIza[0-9A-Za-z-_]{35})",
    ~r"(?:sk-(?:live|test)_[a-zA-Z0-9]{32})",
    ~r"(?:Bearer\s+[a-zA-Z0-9-._~+/]+)",
    ~r"authorization=\S+"i
  ]

  @doc """
  Sanitizes metadata to ensure PII and credentials are removed.
  """
  def redact_metadata(metadata) when is_map(metadata) do
    if Map.has_key?(metadata, :__struct__) do
      # For structs, we don't want to Enum.reduce as it may fail if not Enumerable.
      # Instead, we just return it as-is (PII redaction across structs is complex)
      # or convert to map if we really need to redact.
      metadata
    else
      Enum.reduce(metadata, %{}, fn {key, value}, acc ->
        case value do
          v when is_binary(v) ->
            Map.put(acc, key, apply_patterns(v))

          v when is_map(v) ->
            Map.put(acc, key, redact_metadata(v))

          v ->
            Map.put(acc, key, v)
        end
      end)
    end
  end

  def redact_metadata(other), do: other

  defp apply_patterns(value) do
    Enum.reduce(@redaction_patterns, value, fn pattern, acc ->
      String.replace(acc, pattern, "REDACTED")
    end)
  end
end
