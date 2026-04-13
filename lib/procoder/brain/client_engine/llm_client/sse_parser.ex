defmodule ProCoder.Brain.Client.SSEParser do
  @moduledoc """
  High-performance SSE stream parser for LLM token ingestion.

  This module implements a line-buffered state machine for parsing Server-Sent Events (SSE)
  as defined in the HTML5 specification. It extracts data frames, performs hardened JSON
  decoding, and propagates events to the orchestrating GenServer.
  """

  use GenServer
  require Logger

  alias ProCoder.Brain.Client.Requirements

  @type state :: %{
    buffer: binary(),
    caller: pid(),
    config: keyword()
  }

  @doc """
  Starts the SSE Parser process.
  """
  def start_link(caller: caller, config: config) do
    GenServer.start_link(__MODULE__, %{caller: caller, config: config})
  end

  @impl true
  def init(%{caller: caller, config: config}) do
    {:ok, %{buffer: "", caller: caller, config: config}}
  end

  @doc """
  Processes a raw binary chunk from the network stream.
  """
  def process_chunk(pid, chunk) when is_binary(chunk) do
    GenServer.cast(pid, {:process_chunk, chunk})
  end

  @impl true
  def handle_cast({:process_chunk, chunk}, %{buffer: buffer, caller: caller} = state) do
    new_buffer = buffer <> chunk
    
    # Check for SSE delimiter (\n\n)
    case String.split(new_buffer, "\n\n", parts: 2) do
      [frame, rest] ->
        handle_frame(frame, caller)
        {:noreply, %{state | buffer: rest}}

      [_incomplete] ->
        # Enforce buffer limit (back-pressure)
        if byte_size(new_buffer) > Keyword.get(state.config, :max_buffer_size, 10_000) do
          send(caller, {:sse_error, :buffer_overflow})
          {:stop, :buffer_overflow, state}
        else
          {:noreply, %{state | buffer: new_buffer}}
        end
    end
  end

  defp handle_frame(frame, caller) do
    lines = String.split(frame, "\n")
    
    Enum.each(lines, fn line ->
      cond do
        String.starts_with?(line, "data: ") ->
          data = String.replace_prefix(line, "data: ", "")
          parse_data(data, caller)

        String.starts_with?(line, "event: ") ->
          event = String.replace_prefix(line, "event: ", "")
          send(caller, {:sse_event, event})

        line == "" -> :noop
        true -> :noop
      end
    end)
  end

  defp parse_data("[DONE]", caller) do
    send(caller, :sse_done)
  end

  defp parse_data(data, caller) do
    case Requirements.parse_frame(data) do
      {:ok, decoded} ->
        send(caller, {:sse_message, decoded})
      {:error, :malformed_json_frame} ->
        send(caller, {:sse_error, :malformed_json_frame})
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    send(state.caller, {:sse_error, :timeout})
    {:stop, :normal, state}
  end
end
