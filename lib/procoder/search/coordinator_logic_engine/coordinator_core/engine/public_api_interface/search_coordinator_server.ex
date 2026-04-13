defmodule ProCoder.Search.Coordinator.Server do
  @moduledoc """
  The SearchCoordinatorServer acts as the primary, fault-tolerant, and asynchronous 
  public API gateway for the ProCoder search ecosystem. It serves as the bridge 
  between external callers (Planner, LLM Brain) and the SearchCoordinator gen_statem.
  """

  use GenServer
  require Logger

  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.Search.Coordinator.Telemetry
  alias ProCoder.Search.Adapters.{LSPAdapter, TextEngineAdapter, CDMSAdapter}
  alias ProCoder.Search.VectorStoreAdapter
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager

  @type options :: keyword()
  @type search_error :: {:error, :system_failure}

  # --- API Interface ---

  @doc """
  Initiates a search query. 
  Supported options: :worktree_id (required), :timeout (optional)
  """
  @spec search(String.t(), options()) :: {:ok, [SearchResult.t()]} | search_error()
  def search(query, options) do
    session_id = Keyword.get(options, :session_id)

    if SessionManager.authorized?(session_id) do
      # Default timeout increased to 120s for discovery reliability
      GenServer.call(__MODULE__, {:search, query, options}, Keyword.get(options, :timeout, 120_000))
    else
      {:error, :unauthorized_context}
    end
  end

  @doc """
  Observability hook to query current search engine health.
  """
  @spec get_status() :: map()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Hot-swap configuration for the search layer.
  """
  @spec update_config(map()) :: :ok
  def update_config(new_config) do
    GenServer.cast(__MODULE__, {:update_config, new_config})
  end

  # --- GenServer Callbacks ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    {:ok, %{
      config: Map.new(opts),
      stats: %{requests: 0, errors: 0}
    }}
  end

  @impl true
  def handle_call({:search, query, options}, from, state) do
    session_id = Keyword.get(options, :session_id, "default")
    
    # 1. Instrumentation: Start
    Telemetry.emit_start(session_id, query, %{workspace_entropy: 0})
    
    # 2. Spawn a Task to perform the search without blocking the GenServer mailbox
    Task.start(fn ->
      # We delegate to the stateless handler directly to avoid serializing through a single process
      # The FsmCoreLogicEngine is primarily a wrapper for handle_cascade in this synchronous flow.
      result = 
        try do
          # Mirror the logic in FsmCoreLogicEngine.idle/3
          type = Keyword.get(options, :type)
          chain = case type do
            :cdms -> [CDMSAdapter]
            :vector -> [ProCoder.Search.VectorStoreAdapter]
            :text -> [TextEngineAdapter]
            :lsp -> [LSPAdapter]
            _ -> [LSPAdapter, TextEngineAdapter, VectorStoreAdapter]
          end

          # 1. Resolve worktree_root from session metadata
          worktree_root = 
            case SessionManager.get_session(session_id) do
              {:ok, %{worktree: path}} -> path
              _ -> nil
            end

          options = Keyword.put_new(options, :worktree_root, worktree_root)

          cascade_state = %{
            results: [],
            degradation_depth: 0,
            failures: [],
            session_id: session_id,
            options: options
          }

          results = ProCoder.Search.Coordinator.Logic.SearchErrorHandler.handle_cascade(query, chain, cascade_state)
          {:ok, results}
        rescue
          e -> 
            Logger.error("Search task failed: #{inspect(e)}")
            {:error, :system_failure}
        end

      # 3. Respond to the caller and emit telemetry
      case result do
        {:ok, results} ->
          Telemetry.emit_stop(session_id, %{total_duration: 0, final_state: :success})
          GenServer.reply(from, {:ok, results})
          
        _ ->
          Telemetry.emit_stop(session_id, %{total_duration: 0, final_state: :error})
          GenServer.reply(from, {:error, :system_failure})
      end
    end)

    {:noreply, update_stats(state, :requested)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast({:update_config, new_config}, state) do
    {:noreply, %{state | config: Map.merge(state.config, new_config)}}
  end

  # --- Internal Helpers ---

  defp update_stats(state, :requested) do
    %{state | stats: %{state.stats | requests: state.stats.requests + 1}}
  end

  defp update_stats(state, :success) do
    %{state | stats: %{state.stats | requests: state.stats.requests + 1}}
  end

  defp update_stats(state, :error) do
    %{state | stats: %{state.stats | errors: state.stats.errors + 1}}
  end
end
