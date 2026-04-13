defmodule ProCoder.Brain.ClientEngine.EmbeddingWorker do
  @moduledoc """
  Worker for generating text embeddings using Bumblebee and EXLA.
  It loads the model on startup and serves synchronous embedding requests.
  """
  use GenServer
  require Logger



  @base_url Application.compile_env(:procoder, [:ml_bridge, :base_url], "http://localhost:5000")

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def generate(text) do
    GenServer.call(__MODULE__, {:generate, text}, :infinity)
  end

  def calculate_salience(text, provenance \\ %{}) do
    GenServer.call(__MODULE__, {:calculate_salience, text, provenance}, :infinity)
  end

  @impl true
  def init(_opts) do
    Logger.info("EmbeddingWorker: Initialized as Bridge Client for #{@base_url}")
    {:ok, %{base_url: @base_url}}
  end

  @impl true
  def handle_call({:generate, text}, _from, state) do
    url = "#{state.base_url}/api/v1/embed"
    
    case Req.post(url, json: %{text: text}) do
      {:ok, %{status: 200, body: %{"vector" => vector}}} ->
        {:reply, {:ok, vector}, state}
      
      {:ok, response} ->
        Logger.error("EmbeddingWorker: API error #{response.status}: #{inspect(response.body)}")
        {:reply, {:error, :api_error}, state}

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Connection error: #{inspect(reason)}")
        {:reply, {:error, :connection_failed}, state}
    end
  end

  @impl true
  def handle_call({:calculate_salience, text, provenance}, _from, state) do
    url = "#{state.base_url}/api/v1/salience"
    
    case Req.post(url, json: %{text: text, provenance: provenance}) do
      {:ok, %{status: 200, body: %{"score" => score}}} ->
        {:reply, {:ok, score}, state}
      
      {:ok, response} ->
        Logger.error("EmbeddingWorker: Salience API error #{response.status}: #{inspect(response.body)}")
        {:reply, {:ok, 0.5}, state} # Fallback to neutral

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Salience connection error: #{inspect(reason)}")
        {:reply, {:ok, 0.5}, state} # Fallback
    end
  end
end
