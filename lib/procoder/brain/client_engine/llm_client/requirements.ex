defmodule ProCoder.Brain.Client.Requirements do
  @moduledoc """
  Defines the dependency requirements and foundational data structures for the
  ProCoder LLM Client. This module provides the specification for streaming
  token handling, SSE parsing, and JSON ingestion, ensuring compatibility with
  the high-concurrency requirements of the BEAM-based architecture.
  """

  @doc """
  Returns the list of required external dependencies for the LLM Client.
  These dependencies are mandated by the system architecture to ensure
  robust HTTP/2 pooling, serialization, and stream processing.
  """
  def dependencies do
    [
      {:finch, "~> 0.17.0"},  # HTTP/2 connection pooling
      {:jason, "~> 1.4.0"},   # High-performance JSON serialization
      {:req, "~> 0.4.0"}     # Robust API orchestration
    ]
  end

  @doc """
  Defines the expected structure for incoming SSE frames.
  Each frame must be decoded into this structure before further processing
  by the gen_statem orchestration layer.
  """
  defstruct correlation_id: nil,
            event_type: :message,
            payload: %{},
            timestamp: nil

  @type t :: %__MODULE__{
    correlation_id: String.t(),
    event_type: :message | :error | :done | :ping,
    payload: map(),
    timestamp: DateTime.t()
  }

  @doc """
  Hardened JSON decoding logic for SSE streams.
  Ensures that malformed LLM responses are rejected early to maintain
  the stability of the internal state machines.
  """
  def parse_frame(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :malformed_json_frame}
    end
  end

  @doc """
  Back-pressure control configuration for active stream processes.
  Ensures the system does not exceed defined resource limits when
  ingesting tokens from upstream providers.
  """
  def stream_config do
    [
      max_buffer_size: 10_000,
      read_timeout: 5_000,
      retry_attempts: 3
    ]
  end
end
