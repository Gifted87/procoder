defmodule ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine do
  @moduledoc """
  The HistoryStackEngine manages LIFO persistence for ProCoder state snapshots.
  It uses a two-tiered architecture: an ETS-backed hot stack for instant retrieval
  and SQLite (via ProCoder.Repo) for durable cold storage.
  """

  use GenServer
  require Logger

  alias ProCoder.Repo
  alias ProCoder.Persistence.Snapshot, as: SnapshotSchema

  @hot_stack_limit 5

  # --- API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc """
  Persists a new snapshot: calculates SHA-256, stores in DB, updates hot stack.
  """
  def push(session_id, data) do
    GenServer.call(via_tuple(session_id), {:push, data})
  end

  @doc """
  Pops the top snapshot. Replenishes from DB if hot stack is empty.
  """
  def pop(session_id) do
    GenServer.call(via_tuple(session_id), :pop)
  end

  @doc """
  Retrieves a specific snapshot by ID.
  """
  def get(session_id, snapshot_id) do
    GenServer.call(via_tuple(session_id), {:get, snapshot_id})
  end

  @doc """
  Peeks at the top of the hot stack.
  """
  def peek(session_id) do
    GenServer.call(via_tuple(session_id), :peek)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(session_id) do
    table = :ets.new(:history_hot_stack, [:ordered_set, :protected, {:read_concurrency, true}])
    {:ok, %{session_id: session_id, table: table}}
  end

  @impl true
  def handle_call({:push, data}, _from, state) do
    blob = :erlang.term_to_binary(data)
    hash = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
    
    snapshot = %{
      snapshot_id: Ecto.UUID.generate(),
      session_id: state.session_id,
      memory_blob: blob,
      integrity_hash: hash,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    # Persistence (Cold) — guarded: a corrupted/unavailable DB must never crash the GenServer.
    # The snapshot is still kept hot in ETS so the agent can continue operating.
    try do
      Repo.insert!(%SnapshotSchema{
        snapshot_id: snapshot.snapshot_id,
        session_id: state.session_id,
        memory_blob: snapshot.memory_blob,
        integrity_hash: snapshot.integrity_hash
      })
    rescue
      e ->
        Logger.warn("[HistoryStackEngine] DB error on push for #{state.session_id}: #{inspect(e)}. Snapshot kept in ETS only.")
        self_heal_if_corrupted(e)
    end

    # Update Hot (ETS)
    :ets.insert(state.table, {snapshot.inserted_at, snapshot})
    evict_hot_stack(state.table)

    {:reply, {:ok, snapshot.snapshot_id}, state}
  end

  @impl true
  def handle_call(:pop, _from, state) do
    case :ets.last(state.table) do
      :"$end_of_table" ->
        # Replenish from DB
        case fetch_latest_from_db(state.session_id) do
          nil -> {:reply, {:error, :empty}, state}
          snap ->
            :ets.insert(state.table, {snap.inserted_at, snap})
            {:reply, {:ok, snap}, state}
        end
      last_key ->
        [{_, snap}] = :ets.lookup(state.table, last_key)
        :ets.delete(state.table, last_key)
        {:reply, {:ok, snap}, state}
    end
  end

  @impl true
  def handle_call({:get, snapshot_id}, _from, state) do
    # Try ETS
    case Enum.find(:ets.tab2list(state.table), fn {_, s} -> s.snapshot_id == snapshot_id end) do
      {_, snap} -> {:reply, {:ok, snap}, state}
      nil ->
        # Try DB — guard against corruption or transient disk errors
        db_result =
          try do
            Repo.get_by(SnapshotSchema, snapshot_id: snapshot_id)
          rescue
            e ->
              Logger.warn("[HistoryStackEngine] DB error on get #{snapshot_id}: #{inspect(e)}")
              self_heal_if_corrupted(e)
              nil
          end

        case db_result do
          nil -> {:reply, {:error, :not_found}, state}
          snap ->
            with :ok <- verify_integrity(snap) do
              {:reply, {:ok, snap}, state}
            else
              error -> {:reply, error, state}
            end
        end
    end
  end

  @impl true
  def handle_call(:peek, _from, state) do
    case :ets.last(state.table) do
      :"$end_of_table" ->
        # Hydrate from DB on cache miss
        case fetch_latest_from_db(state.session_id) do
          nil -> {:reply, {:error, :empty}, state}
          snap ->
            # Repopulate the hot stack
            :ets.insert(state.table, {snap.inserted_at, snap})
            {:reply, {:ok, snap}, state}
        end
      key ->
        [{_, snap}] = :ets.lookup(state.table, key)
        {:reply, {:ok, snap}, state}
    end
  end

  # --- Helpers ---

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "history_stack_#{session_id}"}}

  defp verify_integrity(snapshot) do
    hash = :crypto.hash(:sha256, snapshot.memory_blob) |> Base.encode16(case: :lower)
    if hash == snapshot.integrity_hash, do: :ok, else: {:error, :integrity_failure}
  end

  defp evict_hot_stack(table) do
    if :ets.info(table, :size) > @hot_stack_limit do
      first_key = :ets.first(table)
      :ets.delete(table, first_key)
    end
  end

  defp fetch_latest_from_db(session_id) do
    import Ecto.Query

    try do
      Repo.one(from s in SnapshotSchema, where: s.session_id == ^session_id, order_by: [desc: s.inserted_at], limit: 1)
    rescue
      e ->
        Logger.warn("[HistoryStackEngine] DB error fetching snapshot for #{session_id}: #{inspect(e)}. Treating as empty.")
        self_heal_if_corrupted(e)
        nil
    end
  end

  defp self_heal_if_corrupted(e) do
    error_str = inspect(e)
    if String.contains?(error_str, "database disk image is malformed") do
      Logger.error("[HistoryStackEngine] DB Corruption detected! Triggering auto-delete and self-heal...")
      db_path = Application.get_env(:procoder, ProCoder.Repo)[:database]
      if db_path do
        File.rm(db_path)
        File.rm(db_path <> "-shm")
        File.rm(db_path <> "-wal")
        Logger.info("[HistoryStackEngine] Purged corrupted database files: #{db_path}")

        # Bring schema back online
        spawn(fn ->
          Process.sleep(100) # Give file handles a moment
          try do
            ProCoder.Search.CodeGraphEngine.ensure_schema!()
            Logger.info("[HistoryStackEngine] Database schema self-healed and ready.")
          rescue
            err -> Logger.warning("[HistoryStackEngine] Self-heal schema creation failed: #{inspect(err)}")
          end
        end)
      end
    end
  end
end
