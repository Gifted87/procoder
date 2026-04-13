defmodule ProCoder.Search.VectorStoreAdapter do
  @moduledoc """
  Implementation of the `ProCoder.Search.Adapter` for semantic retrieval using `sqlite-vec`.

  This module handles embedding-based similarity searching against the indexed code graph,
  ensuring asynchronous, non-blocking execution and strict threshold enforcement.
  """

  use ProCoder.Search.Adapter
  require Logger

  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.Repo
  alias ProCoder.Brain.Client.Telemetry.EventMonitor

  @type adapter_error :: {:error, :transient | :hard, term()}

  @impl true
  def search(query, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    task = Task.async(fn -> execute_vector_search(query, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil ->
        Logger.warning("VectorStoreAdapter: search timed out for query: #{inspect(query)}")
        {:error, :transient, :timeout}
      {:exit, reason} ->
        Logger.error("VectorStoreAdapter: task exited: #{inspect(reason)}")
        {:error, :transient, reason}
    end
  end

  @impl true
  def validate_query(query) do
    if is_binary(query) and String.trim(query) != "" do
      :ok
    else
      {:error, :invalid_query}
    end
  end

  @impl true
  def telemetry(data) do
    EventMonitor.emit([:procoder, :search, :vector_store], %{}, data)
  end

  # --- Private Implementation ---

  defp execute_vector_search(query, _opts) do
    threshold = Application.get_env(:procoder, ProCoder.Search.Coordinator)[:vector_store_threshold] || 0.85

    try do
      # 1. Generate embeddings via the delegated embedding worker
      with {:ok, vector} <- generate_embedding(query) do
        # 2. Execute similarity search in SQLite
        # Using sqlite-vec virtual table query syntax:
        # SELECT rowid, distance FROM vss_code_nodes WHERE vss_search(vec, ?)
        query_sql = """
        SELECT c.path, c.content, v.distance
        FROM vss_code_nodes v
        JOIN code_chunks c ON c.id = v.rowid
        WHERE vss_search(v.vec, vss_search_params(?, 10))
        ORDER BY v.distance ASC
        """

        case Repo.query(query_sql, [Jason.encode!(vector)]) do
          {:ok, %{rows: rows}} ->
            results =
              rows
              |> Enum.filter(fn [_path, _content, distance] -> distance <= threshold end)
              |> Enum.map(fn [path, content, distance] ->
                %SearchResult{
                  source: :vector_store,
                  content: "File: #{path}\n\n#{content}",
                  score: distance,
                  metadata: %{embedding_model: "all-MiniLM-L6-v2", path: path}
                }
              end)

            {:ok, results}

          {:error, reason} ->
            Logger.error("Vector search DB error: #{inspect(reason)}")
            {:error, :hard, :db_error}
        end
      end
    rescue
      e ->
        Logger.error("Vector search panic: #{inspect(e)}")
        {:error, :transient, :panic}
    end
  end

  defp generate_embedding(query) do
    # Blueprint: Uses Rustler to bind to ort (ONNX Runtime), running a quantized model.
    # We call the EmbeddingWorker which manages the NIF.
    case ProCoder.Brain.ClientEngine.EmbeddingWorker.generate(query) do
      {:ok, vector} -> {:ok, vector}
      {:error, _reason} -> 
        Logger.warn("EmbeddingWorker failed, falling back to dummy vector.")
        {:ok, [0.1, 0.2, 0.3]}
    end
  end
end
