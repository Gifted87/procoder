defmodule ProCoder.Search.CodeGraph.Native do
  @moduledoc """
  Low-level NIF interface for tree-sitter based AST parsing and indexing.
  """
  use Rustler, otp_app: :procoder, crate: "codegraph_engine"

  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def hello(), do: :erlang.nif_error(:nif_not_loaded)
  def parse_source(_lang, _source), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule ProCoder.Search.CodeGraphEngine do
  @moduledoc """
  High-level interface for managing the CodeGraph.
  Orchestrates indexing, relationships extraction, and persistence.
  """
  require Logger

  alias ProCoder.Search.CodeGraph.Native
  alias ProCoder.Repo

  @directory_blacklist [
    # Elixir / Mix
    "_build", "deps",
    # JavaScript / Node
    "node_modules", ".npm", ".yarn", "dist", "build", ".next", ".nuxt",
    # Python
    "venv", ".venv", "__pycache__", ".tox", "site-packages", "egg-info", ".eggs", ".pyc",
    # Java / JVM
    "target", ".gradle", ".mvn",
    # Version control
    ".git", ".svn", ".hg",
    # IDE / editor
    ".elixir_ls", ".idea", ".vscode", ".eclipse",
    # ProCoder internal
    "_antigravity", ".procoder", ".shadow", ".archives", "workspaces", ".gemini",
    # Generic
    "tmp", "log", "logs", "cache", ".cache", "coverage", ".nyc_output",
  ]
  
  def directory_blacklist, do: @directory_blacklist


  @file_blacklist [
    "agent_message.md",
    "workspace_status.md"
  ]


  @extension_whitelist [
    ".ex", ".exs", ".js", ".jsx", ".ts", ".tsx", ".py", ".pyw", ".rb", ".erb",
    ".java", ".kt", ".kts", ".cs", ".php", ".c", ".cpp", ".cc", ".h", ".hpp",
    ".go", ".rs", ".swift", ".scala", ".hs", ".lua", ".pl", ".pm", ".r", ".dart",
    ".zig", ".nim", ".jl", ".m", ".mm", ".s", ".asm", ".clj", ".cljs", ".vue",
    ".svelte", ".css", ".scss", ".sass", ".less", ".html", ".xml", ".json", ".toml",
    ".yaml", ".yml", ".ini", ".conf", ".sh", ".bash", ".zsh", ".ps1", ".bat", ".sql",
    ".md", ".txt", ".rst", ".adoc", ".proto", ".graphql"
  ]

  @doc """
  Indexes the entire codebase configured via SOURCE_ROOT.
  """
  def index_codebase do
    Task.start(fn ->
      ensure_schema!()
      source_root = System.get_env("PROCODER_SOURCE_ROOT") || Application.get_env(:procoder, ProCoder.SessionManager)[:source_root]
      
      Logger.info("IndexerWorker: Starting recursive codebase crawl at #{source_root}...")
      
      files = crawl_directory(source_root)
      Logger.info("Crawler found #{length(files)} indexable files.")
      
      Enum.each(files, &index_file/1)
      
      Logger.info("Background indexing completed.")
    end)
  end

  defp crawl_directory(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          cond do
            File.dir?(path) ->
              if indexable_dir?(entry) do
                crawl_directory(path)
              else
                []
              end
            indexable_file?(path) ->
              [path]
            true ->
              []
          end
        end)
      _ -> []
    end
  end

  defp indexable_dir?(name) do
    name not in @directory_blacklist and not String.starts_with?(name, ".")
  end

  @max_file_bytes 500_000  # 500 KB — skip large binary/generated files

  defp indexable_file?(path) do
    name = Path.basename(path)
    ext = Path.extname(path)
    indexable = 
      ext in @extension_whitelist and 
      not String.starts_with?(name, ".") and
      name not in @file_blacklist

    if indexable do
      case File.stat(path) do
        {:ok, %{size: size}} -> size <= @max_file_bytes
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Ensures that the code_relationships table exists in the database.
  """
  def ensure_schema! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS code_relationships (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT,
      from_node TEXT,
      to_node TEXT,
      inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """)
    
    Repo.query!("CREATE INDEX IF NOT EXISTS idx_code_rel_type ON code_relationships(type)")
    Repo.query!("CREATE INDEX IF NOT EXISTS idx_code_rel_from ON code_relationships(from_node)")
    Repo.query!("CREATE INDEX IF NOT EXISTS idx_code_rel_to ON code_relationships(to_node)")

    # Vector Search Tables
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS code_chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT,
      content TEXT
    )
    """)

    Repo.query!("CREATE VIRTUAL TABLE IF NOT EXISTS vss_code_nodes USING vss0(vec(384))")

    # Tracking for incremental indexing
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS indexed_files (
      path TEXT PRIMARY KEY,
      hash TEXT,
      last_indexed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """)

    # History Snapshots table (for REWIND and history persistence)
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS snapshots (
      id TEXT PRIMARY KEY,
      snapshot_id TEXT,
      session_id TEXT,
      memory_blob BLOB,
      integrity_hash TEXT,
      inserted_at TIMESTAMP,
      updated_at TIMESTAMP
    )
    """)
  end

  @doc """
  Checks if a file with the given path and content hash has already been indexed.
  """
  def indexed?(path) do
    case File.read(path) do
      {:ok, source} ->
        hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
        case Repo.query("SELECT hash FROM indexed_files WHERE path = ?", [path]) do
          {:ok, %{rows: [[existing_hash]]}} -> existing_hash == hash
          _ -> false
        end
      _ -> false
    end
  end

  @doc """
  Indexes a file, extracting semantic relationships and storing them in SQLite.
  """
  def index_file(path) do
    with {:ok, source} <- File.read(path),
         hash <- :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
         lang <- language_from_path(path) do
         
      # Check for incremental skip
      if indexed_and_unchanged?(path, hash) do
        Logger.debug("Incremental: Skipping unchanged file #{path}")
      else
        Logger.debug("Indexing file: #{path}")
        # Clean up old data for this path to avoid duplicates
        cleanup_file_data(path)

        # 1. Vector Semantic Indexing (Chunks)
      if String.trim(source) != "" do
        chunks = chunk_text(source, 500)
        Enum.each(chunks, fn chunk ->
          case Repo.query("INSERT INTO code_chunks (path, content) VALUES (?, ?) RETURNING id", [path, chunk]) do
            {:ok, %{rows: [[chunk_id]]}} ->
              case ProCoder.Brain.ClientEngine.EmbeddingWorker.generate(chunk) do
                {:ok, vector} ->
                  json_vec = Jason.encode!(vector)
                  Repo.query("INSERT INTO vss_code_nodes (rowid, vec) VALUES (?, ?)", [chunk_id, json_vec])
                _ -> :skip
              end
            _ -> :skip
          end
        end)
      end

      # 2. Extract AST relationships
      case Native.parse_source(lang, source) do
        ast when is_map(ast) ->
          relationships = extract_relationships(ast, path)
          Logger.debug("Extracted #{length(relationships)} relationships from #{path}")
          
          Enum.each(relationships, fn {type, from, to} ->
            Repo.query("INSERT INTO code_relationships (type, from_node, to_node) VALUES (?, ?, ?)", [type, from, to])
          end)
        _ -> :ok
      end
      
      # 3. Mark as indexed
      Repo.query("INSERT OR REPLACE INTO indexed_files (path, hash) VALUES (?, ?)", [path, hash])
      
      :ok
      end
    else
      error -> Logger.error("Failed to parse #{path}: #{inspect(error)}")
    end
  end

  @doc """
  Parses a source file and returns its AST structure.
  """
  def parse_file(path) do
    with {:ok, source} <- File.read(path),
         lang <- language_from_path(path) do
      # The NIF returns the AST map directly or an {:error, reason} tuple
      case Native.parse_source(lang, source) do
        {:error, reason} -> {:error, reason}
        ast when is_map(ast) -> {:ok, ast}
        other -> {:error, other}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_relationships(node, path) do
    case node[:node_type] do
      "call" ->
        cond do
          is_defmodule_call?(node) ->
            name = find_module_name_in_call(node)
            [{"defines", path, name}] ++ traverse_children(node, path)

          is_dependency_call?(node) ->
            names = find_all_aliases_in_call(node)
            Enum.map(names, fn name -> {"depends_on", path, name} end) ++ traverse_children(node, path)

          is_module_call?(node) ->
            case find_module_in_dot_call(node) do
              nil -> traverse_children(node, path)
              name -> [{"calls", path, name}] ++ traverse_children(node, path)
            end

          true ->
            traverse_children(node, path)
        end

      "dot" ->
        traverse_children(node, path)

      _ ->
        traverse_children(node, path)
    end
  end

  defp is_defmodule_call?(node) do
    case node[:children] do
      [%{content: "defmodule", node_type: "identifier"} | _] -> true
      _ -> false
    end
  end

  defp is_dependency_call?(node) do
    case node[:children] do
      [%{content: cmd, node_type: "identifier"} | _] when cmd in ["alias", "import", "require", "use"] -> true
      _ -> false
    end
  end

  defp is_module_call?(node) do
    case node[:children] do
      [%{node_type: "dot"} | _] -> true
      _ -> false
    end
  end

  defp find_all_aliases_in_call(node) do
    direct_aliases =
      (node[:children] || [])
      |> Enum.filter(&(&1[:node_type] in ["alias", "dot"]))
      |> Enum.map(& &1[:content])

    arg_aliases =
      (node[:children] || [])
      |> Enum.filter(&(&1[:node_type] == "arguments"))
      |> Enum.flat_map(fn arg_node ->
        (arg_node[:children] || [])
        |> Enum.filter(&(&1[:node_type] in ["alias", "dot"]))
        |> Enum.map(& &1[:content])
      end)

    direct_aliases ++ arg_aliases
  end

  defp find_module_in_dot_call(node) do
    case node[:children] do
      [%{node_type: "dot", content: content} | _] ->
        # For dot nodes (e.g. ProCoder.Repo.query), the part before the last segment is the module
        case String.split(content, ".") do
          [_] -> nil # local call
          parts -> Enum.drop(parts, -1) |> Enum.join(".")
        end
      _ -> nil
    end
  end

  defp find_module_name_in_call(node) do
    # Handle both parenthesized (in arguments) and unparenthesized (direct child) aliases/dots
    target_node =
      Enum.find(node[:children] || [], &(&1[:node_type] in ["alias", "dot"])) ||
      (Enum.find(node[:children] || [], &(&1[:node_type] == "arguments")) || %{})
      |> Map.get(:children, [])
      |> Enum.find(&(&1[:node_type] in ["alias", "dot"]))

    case target_node do
      %{content: name} -> name
      _ -> "UnknownModule"
    end
  end

  defp traverse_children(node, path) do
    Enum.flat_map(node[:children] || [], &extract_relationships(&1, path))
  end


  defp language_from_path(path) do
    ext = Path.extname(path)
    case ext do
      ext when ext in [".ex", ".exs"] -> :elixir
      ext when ext in [".js", ".jsx"] -> :javascript
      ext when ext in [".ts", ".tsx"] -> :typescript
      ext when ext in [".py", ".pyw"] -> :python
      ext when ext in [".c", ".h"] -> :c
      ext when ext in [".cpp", ".cc", ".hpp"] -> :cpp
      ".rb" -> :ruby
      ".java" -> :java
      ".go" -> :go
      ".rs" -> :rust
      ".php" -> :php
      ".cs" -> :csharp
      ".swift" -> :swift
      ".kt" -> :kotlin
      ".scala" -> :scala
      ".lua" -> :lua
      ".sh" -> :bash
      ".sql" -> :sql
      ".md" -> :markdown
      ".txt" -> :text
      ".json" -> :json
      ".yaml" -> :yaml
      ".yml" -> :yaml
      ".xml" -> :xml
      _ -> :code
    end
  end

  defp indexed_and_unchanged?(path, current_hash) do
    case Repo.query("SELECT hash FROM indexed_files WHERE path = ?", [path]) do
      {:ok, %{rows: [[existing_hash]]}} -> existing_hash == current_hash
      _ -> false
    end
  end

  defp cleanup_file_data(path) do
    # Delete chunks and their corresponding VSS nodes (rowid link)
    case Repo.query("SELECT id FROM code_chunks WHERE path = ?", [path]) do
      {:ok, %{rows: rows}} ->
        ids = List.flatten(rows)
        if ids != [] do
          Repo.query("DELETE FROM vss_code_nodes WHERE rowid IN (#{Enum.join(ids, ",")})")
          Repo.query("DELETE FROM code_chunks WHERE path = ?", [path])
        end
      _ -> :ok
    end

    Repo.query("DELETE FROM code_relationships WHERE from_node = ?", [path])
  end

  defp chunk_text(text, max_len) do
    # Simple chunking by length for the demo
    text
    |> String.codepoints()
    |> Enum.chunk_every(max_len)
    |> Enum.map(&Enum.join/1)
  end
end
