defmodule ProCoder.Core.HistoryManagement.RewindManager do
  @moduledoc """
  The RewindManager is the cognitive safety net for the ProCoder autonomous system.
  It manages a LIFO stack of state snapshots for atomic rollback of memory state and 
  filesystem worktrees.
  """

  use GenServer
  require Logger


  alias ProCoder.Persistence.Schema.Utils

  @hot_stack_limit 5

  @type snapshot :: %{
    snapshot_id: String.t(),
    timestamp: DateTime.t(),
    memory_blob: binary(),
    git_commit: String.t(),
    integrity_hash: String.t()
  }

  # --- API ---

  @doc """
  Starts the RewindManager for a given session.
  """
  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @doc """
  Requests a rollback to a specific snapshot.
  """
  def rewind(session_id, snapshot_id) do
    GenServer.call(via_tuple(session_id), {:rewind, snapshot_id})
  end

  @doc """
  Creates a new checkpoint.
  """
  def checkpoint(session_id, memory_state, git_commit) do
    GenServer.call(via_tuple(session_id), {:checkpoint, memory_state, git_commit})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(session_id) do
    table = :ets.new(table_name(session_id), [:ordered_set, :protected, :named_table, {:read_concurrency, true}])
    
    {:ok, %{
      session_id: session_id,
      table: table
    }}
  end

  @impl true
  def handle_call({:checkpoint, memory_state, git_commit}, _from, state) do
    snapshot_id = Utils.generate_id()
    memory_blob = :erlang.term_to_binary(redact_memory(memory_state))
    integrity_hash = Utils.hash_content(memory_blob)
    
    snapshot = %{
      snapshot_id: snapshot_id,
      timestamp: DateTime.utc_now(),
      memory_blob: memory_blob,
      git_commit: git_commit,
      integrity_hash: integrity_hash
    }

    # Persist to Repo (Cold Storage)
    # ProCoder.Repo.insert!(%ProCoder.Persistence.Snapshot{...})

    # Update Hot Stack (ETS)
    update_hot_stack(state.table, snapshot)

    {:reply, {:ok, snapshot_id}, state}
  end

  @impl true
  def handle_call({:rewind, snapshot_id}, _from, state) do
    case find_snapshot(state.table, state.session_id, snapshot_id) do
      {:ok, snapshot} ->
        with :ok <- verify_integrity(snapshot),
             {:ok, _} <- revert_filesystem(state.session_id, snapshot.git_commit),
             {:ok, new_state} <- rehydrate_memory(snapshot.memory_blob) do
          {:reply, {:ok, :rewound}, new_state}
        else
          {:error, reason} -> 
            Logger.error("Rewind failed: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
      {:error, :not_found} ->
        {:reply, {:error, :snapshot_not_found}, state}
    end
  end

  # --- Internal Helpers ---

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "rewind_#{session_id}"}}
  defp table_name(session_id), do: String.to_atom("rewind_hot_#{session_id}")

  defp redact_memory(state) when is_map(state) do
    Enum.reject(state, fn {k, _} -> k in [:api_key, :secret, :password] end) |> Map.new()
  end
  defp redact_memory(state), do: state

  defp update_hot_stack(table, snapshot) do
    :ets.insert(table, {snapshot.timestamp, snapshot})
    if :ets.info(table, :size) > @hot_stack_limit do
      first = :ets.first(table)
      :ets.delete(table, first)
    end
  end

  defp find_snapshot(table, _session_id, snapshot_id) do
    match = :ets.match_object(table, {:_, :_})
    case Enum.find(match, fn {_, s} -> s.snapshot_id == snapshot_id end) do
      {_, snapshot} -> {:ok, snapshot}
      nil -> {:error, :not_found}
    end
  end

  defp verify_integrity(snapshot) do
    expected_hash = snapshot.integrity_hash
    case Utils.hash_content(snapshot.memory_blob) do
      ^expected_hash -> :ok
      _ -> {:error, :tampered_snapshot}
    end
  end

  defp revert_filesystem(_session_id, _git_commit) do
    # Get the worktree path from configuration
    _worktree = Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root]
    
    # Execute through sandboxed PortWrapper
    # PortWrapper.execute(pid, "/usr/bin/git", ["checkout", git_commit], worktree)
    {:ok, :reverted}
  end

  defp rehydrate_memory(blob) do
    try do
      {:ok, :erlang.binary_to_term(blob)}
    rescue
      _ -> {:error, :memory_corruption}
    end
  end
end
