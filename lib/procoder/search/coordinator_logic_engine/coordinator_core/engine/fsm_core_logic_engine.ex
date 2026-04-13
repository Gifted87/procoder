defmodule ProCoder.Search.CoordinatorLogicEngine.FsmCoreLogicEngine do
  @moduledoc """
  Search Coordinator state machine implemented using `gen_statem`.
  Manages the lifecycle and orchestration of search requests.
  """
  @behaviour :gen_statem

  # --- API ---
  
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(args) do
    :gen_statem.start_link({:local, :search_coordinator}, __MODULE__, args, [])
  end

  # --- gen_statem callbacks ---

  @impl :gen_statem
  def callback_mode(), do: :state_functions

  @impl :gen_statem
  def init(_args) do
    # Initial state: :idle
    {:ok, :idle, %{}}
  end

  alias ProCoder.Search.Coordinator.Logic.SearchErrorHandler
  alias ProCoder.Search.Adapters.{LSPAdapter, TextEngineAdapter, CDMSAdapter}
  alias ProCoder.Search.VectorStoreAdapter

  # --- State: idle ---

  def idle({:call, from}, {:search, query, options}, data) do
    # 1. Resolve worktree_root from session metadata
    session_id = Keyword.get(options, :session_id, "default")
    worktree_root = 
      case ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager.get_session(session_id) do
        {:ok, %{worktree: path}} -> path
        _ -> nil
      end

    options = Keyword.put_new(options, :worktree_root, worktree_root)

    # 2. Initialize cascade state
    state = %{
      results: [],
      degradation_depth: 0,
      failures: [],
      session_id: session_id,
      options: options
    }

    # 3. Define adapter chain based on type option
    type = Keyword.get(options, :type)
    chain = case type do
      :cdms -> [CDMSAdapter]
      :vector -> [VectorStoreAdapter]
      :text -> [TextEngineAdapter]
      :lsp -> [LSPAdapter]
      _ -> [LSPAdapter, TextEngineAdapter, VectorStoreAdapter]
    end

    # 4. Execute cascade
    results = SearchErrorHandler.handle_cascade(query, chain, state)

    # 5. Success reply (stateless for now, staying in idle)
    {:keep_state, data, [{:reply, from, {:ok, results}}]}
  end

  def idle(:cast, {:start_search, search_id}, _data) do
    # Transition to :searching (Legacy/Asynchronous flow)
    {:next_state, :searching, %{search_id: search_id}}
  end

  def idle(event_type, event_content, data) do
    handle_event(event_type, event_content, :idle, data)
  end

  # --- State: searching ---

  def searching(:cast, {:search_complete, result}, data) do
    # Logic to handle results
    {:next_state, :processing, Map.put(data, :result, result)}
  end

  def searching(event_type, event_content, data) do
    handle_event(event_type, event_content, :searching, data)
  end

  # --- State: processing ---

  def processing(:cast, :finalize, _data) do
    # Transition back to :idle
    {:next_state, :idle, %{}}
  end

  def processing(event_type, event_content, data) do
    handle_event(event_type, event_content, :processing, data)
  end

  # --- Helpers ---

  @impl true
  def handle_event(_type, _content, _state, _data) do
    # Default event handling
    :keep_state_and_data
  end

  @impl :gen_statem
  def terminate(_reason, _state, _data) do
    :ok
  end

  @impl :gen_statem
  def code_change(_vsn, state, data, _extra) do
    {:ok, state, data}
  end
end
