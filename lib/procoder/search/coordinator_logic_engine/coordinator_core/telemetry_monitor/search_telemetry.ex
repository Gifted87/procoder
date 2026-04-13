defmodule ProCoder.Search.Coordinator.Telemetry do
  @moduledoc """
  Telemetry instrumentation for the 'Gradient of Precision' search cascade.

  Tracks search latency, cascade degradation, and failure rates across
  LSP, TextEngine, and VectorStore layers. Ensures PII/path redaction
  before dispatching events to the telemetry bus.
  """

  require Logger

  alias ProCoder.Brain.Client.Telemetry.EventMonitor

  @telemetry_prefix [:procoder, :search, :coordinator]

  @doc """
  Signals the start of a search cascade.
  """
  @spec emit_start(session_id :: binary(), query :: String.t(), metadata :: map()) :: :ok
  def emit_start(session_id, query, metadata) do
    dispatch(:start, %{start_time: System.monotonic_time(:microsecond)}, %{
      session_id: session_id,
      query: query,
      query_length: String.length(query),
      workspace_entropy: Map.get(metadata, :workspace_entropy, 0)
    })
  end

  @doc """
  Records the result of a specific search layer (LSP, TextEngine, VectorStore).
  """
  @spec emit_layer_result(
          session_id :: binary(),
          layer :: atom(),
          result :: :success | :failure,
          metadata :: map()
        ) :: :ok
  def emit_layer_result(session_id, layer, result, metadata) do
    measurements = %{
      duration: Map.get(metadata, :duration, 0)
    }

    dispatch([:layer, layer, result], measurements, %{
      session_id: session_id,
      layer: layer,
      status: result,
      error_type: Map.get(metadata, :error_type),
      result_count: Map.get(metadata, :result_count, 0)
    })
  end

  @doc """
  Records the completion of the cascade.
  """
  @spec emit_stop(session_id :: binary(), metadata :: map()) :: :ok
  def emit_stop(session_id, metadata) do
    measurements = %{
      total_duration: Map.get(metadata, :total_duration, 0),
      degradation_depth: Map.get(metadata, :degradation_depth, 0)
    }

    dispatch(:stop, measurements, %{
      session_id: session_id,
      final_state: Map.get(metadata, :final_state, :success)
    })
  end

  # --- Internal Helpers ---

  defp dispatch(event_suffix, measurements, metadata) do
    event_name = @telemetry_prefix ++ List.wrap(event_suffix)

    # Dispatch asynchronously to avoid blocking the Coordinator process.
    # EventMonitor handles redaction of PII and sensitive paths.
    Task.start(fn ->
      try do
        EventMonitor.emit(event_name, measurements, metadata)
      rescue
        e ->
          Logger.error("Telemetry dispatch failed: #{inspect(e)}")
          :ok
      end
    end)

    :ok
  end
end
