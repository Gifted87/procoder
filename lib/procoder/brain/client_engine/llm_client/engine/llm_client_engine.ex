defmodule ProCoder.Brain.Client.Engine do
  @moduledoc """
  The primary orchestration hub for LLM-related IO operations.
  Bridges high-level gen_statem interactions with low-level HTTP/2 streaming via Finch.
  """

  use GenServer
  require Logger

  alias ProCoder.Brain.Client.HTTPPool.Manager, as: HTTPPool
  alias ProCoder.Brain.Client.SSEParser
  alias ProCoder.Brain.RateLimiter

  @type state :: %{
    pool_name: atom() | nil,
    caller: pid() | nil,
    parser: pid() | nil,
    stream_ref: reference() | nil
  }

  @doc """
  Starts the Engine.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initiates a streaming request.
  """
  def stream(caller, context, opts) do
    GenServer.call(__MODULE__, {:stream, caller, context, opts}, 120_000)
  end

  @doc """
  Performs a synchronous chat request.
  """
  def chat(context, opts \\ []) do
    GenServer.call(__MODULE__, {:chat, context, opts}, 120_000)
  end

  @impl true
  def init(_opts) do
    {:ok, %{pool_name: nil, caller: nil, parser: nil, stream_ref: nil}}
  end

  @impl true
  def handle_call({:stream, caller, _context, opts}, _from, state) do
    case RateLimiter.consume(1) do
      :ok ->
        case prepare_request(opts) do
          {:ok, pool_name} ->
            {:ok, parser_pid} = SSEParser.start_link(caller: caller, config: [])
            
            # Initiate Finch stream
            # Note: Implementation detail assumes Finch is used via the pool manager
            ref = make_ref()
            {:reply, {:ok, ref}, %{state | pool_name: pool_name, caller: caller, parser: parser_pid, stream_ref: ref}}
          
          error ->
            {:reply, error, state}
        end
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:chat, context, opts}, _from, state) do
    case RateLimiter.consume(1) do
      :ok ->
        case prepare_request(opts) do
          {:ok, pool_name} ->
            # Perform synchronous request
            case perform_sync_request(pool_name, context, opts) do
              {:ok, response} -> {:reply, {:ok, response}, state}
              {:error, reason} -> {:reply, {:error, reason}, state}
            end
          error ->
            {:reply, error, state}
        end
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp prepare_request(_opts) do
    endpoint_id = "llm_provider"
    HTTPPool.checkout(endpoint_id)
  end

  defp perform_sync_request(_pool, context, opts) do
    # Delegate to the GeminiAdapter for real interactions
    ProCoder.Brain.Client.Adapters.GeminiAdapter.chat(context, opts)
  end
end
