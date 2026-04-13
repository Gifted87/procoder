defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine do
  @moduledoc """
  The PersistenceEngine provides a durable storage and version control layer for the DAG.
  It manages state snapshots, enables audit trails, and facilitates /rewind functionality
  through a two-tiered (Hot/Cold) memory and storage architecture.
  """

  use GenServer
  require Logger

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Validation.GraphValidator


  @type snapshot :: %{
          graph_binary: binary(),
          checksum: String.t(),
          timestamp: DateTime.t(),
          parent_hash: String.t() | nil
        }

  @type state :: %{
          session_id: String.t(),
          hot_stack: list(snapshot()),
          max_hot_history: pos_integer()
        }

  @doc """
  Starts the PersistenceEngine for a specific DAG session.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc """
  Captures a snapshot of the current graph. Offloaded asynchronously.
  """
  @spec take_snapshot(pid() | String.t(), Graph.t()) :: :ok
  def take_snapshot(engine_ref, graph) do
    GenServer.cast(engine_ref, {:snapshot, graph})
  end

  @doc """
  Rolls back to a specific target snapshot.
  """
  @spec rewind(pid() | String.t(), String.t()) :: {:ok, Graph.t()} | {:error, term()}
  def rewind(engine_ref, timestamp) do
    GenServer.call(engine_ref, {:rewind, timestamp})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(session_id) do
    {:ok, %{session_id: session_id, hot_stack: [], max_hot_history: 10}}
  end

  @impl true
  def handle_cast({:snapshot, graph}, state) do
    Task.start(fn ->
      do_persist_snapshot(graph, state.session_id)
      :telemetry.execute([:procoder, :planner, :persistence, :snapshot_taken], %{})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:rewind, timestamp}, _from, state) do
    case do_retrieve_snapshot(state.session_id, timestamp) do
      {:ok, snapshot} ->
        case validate_and_rehydrate(snapshot) do
          {:ok, graph} ->
            :telemetry.execute([:procoder, :planner, :persistence, :rewind_success], %{})
            {:reply, {:ok, graph}, state}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- Private Helpers ---

  defp do_persist_snapshot(graph, session_id) do
    binary = :erlang.term_to_binary(graph)
    hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    snapshot_id = Ecto.UUID.generate()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

    case ProCoder.Repo.query(
      "INSERT INTO snapshots (id, snapshot_id, session_id, memory_blob, integrity_hash, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [Ecto.UUID.generate(), snapshot_id, session_id, binary, hash, now, now]
    ) do
      {:ok, _} ->
        Logger.debug("[PersistenceEngine] Snapshot #{snapshot_id} persisted for session #{session_id}")
      {:error, reason} ->
        Logger.error("[PersistenceEngine] Failed to persist snapshot: #{inspect(reason)}")
    end
  end

  defp do_retrieve_snapshot(session_id, timestamp) do
    ts_str = to_string(timestamp)
    case ProCoder.Repo.query(
      "SELECT memory_blob, integrity_hash FROM snapshots WHERE session_id = ? AND inserted_at <= ? ORDER BY inserted_at DESC LIMIT 1",
      [session_id, ts_str]
    ) do
      {:ok, %{rows: [[blob, hash]]}} ->
        {:ok, %{graph_binary: blob, checksum: hash}}
      {:ok, %{rows: []}} ->
        {:error, :not_found}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_and_rehydrate(snapshot) do
    try do
      # 1. Integrity check
      current_hash = :crypto.hash(:sha256, snapshot.graph_binary) |> Base.encode16(case: :lower)
      if current_hash != snapshot.checksum, do: raise("Integrity Mismatch")

      # 2. Rehydration
      graph = :erlang.binary_to_term(snapshot.graph_binary)

      # 3. Validation
      case GraphValidator.validate_all!(graph, %{}) do
        :ok -> {:ok, graph}
        {:error, reason, _} -> {:error, reason}
      end
    rescue
      _ -> {:error, :rehydration_failed}
    end
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "persistence_#{session_id}"}}
end
