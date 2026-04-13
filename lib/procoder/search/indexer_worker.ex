defmodule ProCoder.Search.IndexerWorker do
  @moduledoc """
  A background worker that triggers codebase indexing on startup.
  """
  use GenServer
  require Logger
  alias ProCoder.Search.CodeGraphEngine

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Trigger indexing after a short delay to allow system stabilization
    Process.send_after(self(), :trigger_indexing, 1000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:trigger_indexing, state) do
    Logger.info("IndexerWorker: Triggering automated codebase indexing...")
    CodeGraphEngine.index_codebase()
    {:noreply, state}
  end
end
