defmodule ProCoder.Skills.DatabaseDiscoverySkill do
  @moduledoc """
  Skill for semantic auditing of the ProCoder CodeGraph database.
  Provides high-level tools for querying text chunks and AST relationships.
  """
  require Logger
  alias ProCoder.Repo

  @doc """
  Queries indexable code chunks semantically using vector embeddings.
  """
  def query_chunks(args) do
    query = args["query"]
    limit = Map.get(args, "limit", 5)

    case ProCoder.Brain.ClientEngine.EmbeddingWorker.generate(query) do
      {:ok, vector} ->
        # Using sqlite-vec syntax for vss_search on the vec field
        # The virtual table `vss_code_nodes` is joined back to `code_chunks` via rowid
        sql = """
        SELECT c.id, c.path, c.content, v.distance
        FROM vss_code_nodes v
        JOIN code_chunks c ON c.id = v.rowid
        WHERE vss_search(v.vec, vss_search_params(?, ?))
        ORDER BY v.distance ASC
        """
        
        json_vec = Jason.encode!(vector)
        
        case Repo.query(sql, [json_vec, limit]) do
          {:ok, %{rows: rows}} ->
            formatted = Enum.map(rows, fn [id, path, content, distance] ->
              "[Sim: #{Float.round(distance, 3)}] #{path} (ID: #{id}):\n#{content}"
            end) |> Enum.join("\n---\n")
            {:ok, "Semantic matching chunks:\n#{formatted}"}
          {:error, reason} ->
            {:error, "CodeGraph VSS query failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
         Logger.warning("Embedding logic disconnected, falling back to text search: #{inspect(reason)}")
         # Fallback to naive LIKE if ML bridge fails
         fallback_sql = "SELECT id, path, content FROM code_chunks WHERE content LIKE ? LIMIT ?"
         case Repo.query(fallback_sql, ["%#{query}%", limit]) do
            {:ok, %{rows: rows}} ->
              formatted = Enum.map(rows, fn [id, path, content] ->
                "[ID: #{id}] #{path}:\n#{content}"
              end) |> Enum.join("\n---\n")
              {:ok, "Matching chunks (Fallback to LIKE pattern):\n#{formatted}"}
            {:error, reason} ->
              {:error, "Database query failed: #{inspect(reason)}"}
         end
    end
  end

  @doc """
  Lists semantic relationships between code nodes.
  Supported types: 'defines', 'calls', 'depends_on'.
  """
  def list_relationships(args) do
    type = args["type"]
    query = args["query"] || ""
    limit = Map.get(args, "limit", 10)

    sql = "SELECT from_node, to_node FROM code_relationships WHERE type = ? AND (from_node LIKE ? OR to_node LIKE ?) LIMIT ?"
    like_query = "%#{query}%"
    
    case Repo.query(sql, [type, like_query, like_query, limit]) do
      {:ok, %{rows: rows}} ->
        formatted = Enum.map(rows, fn [from, to] ->
          "#{from} -> #{to}"
        end) |> Enum.join("\n")
        {:ok, "Relationships (#{type}) for '#{query}':\n#{formatted}"}
      {:error, reason} ->
        {:error, "Relationship lookup failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Summarizes the current indexing state.
  """
  def describe_schema(_args) do
    chunk_count = Repo.query!("SELECT COUNT(*) FROM code_chunks").rows |> List.first() |> List.first()
    rel_count = Repo.query!("SELECT COUNT(*) FROM code_relationships").rows |> List.first() |> List.first()
    
    summary = """
    ProCoder CodeGraph Overview:
    - Indexed Chunks: #{chunk_count}
    - Semantic Relationships: #{rel_count}
    - Vector Nodes: (SQLite VSS enabled)
    
    Tables:
    - code_chunks: (id, path, content)
    - code_relationships: (id, type, from_node, to_node)
    - vss_code_nodes: Vector search index
    """
    {:ok, summary}
  end
end
