defmodule ProCoder.Search.Adapters.TextEngineAdapter do
  @moduledoc """
  The `TextEngineAdapter` implementation of the `ProCoder.Search.Adapter` behavior.
  
  This engine utilizes `ripgrep` via the `ProCoder.Actuator.PortWrapper` to perform
  filesystem-wide text searches within the sandboxed worktree. It provides
  non-blocking execution, standardized result normalization, and telemetry reporting.
  """

  use ProCoder.Search.Adapter
  require Logger

  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.Brain.Client.Telemetry.EventMonitor


  # Restored code to prevent regressions
  # alias ProCoder.Actuator.PortWrapper
  # @ripgrep_path System.find_executable("rg") || "rg"
  # @default_timeout 5_000

  @impl true
  def search(query, opts) do
    worktree = Keyword.fetch!(opts, :worktree_root)

    telemetry(%{action: :search_start, query: query})

    case System.find_executable("rg") do
      nil -> search_with_grep(query, worktree, opts)
      rg_path -> search_with_rg(rg_path, query, worktree, opts)
    end
  end

  # Directories to exclude from text search — mirrors @directory_blacklist in CodeGraphEngine
  @rg_exclude_globs [
    "_build", "deps", ".git", "node_modules",
    "venv", ".venv", "__pycache__", ".elixir_ls",
    ".shadow", ".archives", ".procoder", ".gemini", "_antigravity",
    "tmp", "log", ".idea", ".vscode", "workspaces",
    "*.beam", "*.pyc", "*.class", "*.o", "*.so", "*.deb", "*.rpm",
    "*.whl", "*.egg-info", "*.lock",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.ico", "*.svg",
    "*.mp4", "*.mp3", "*.zip", "*.tar", "*.gz", "*.rar",
    "agent_message.md", "*/agent_message.md", ".acn", "*/.acn/*"
  ]

  @rg_max_results 50

  defp search_with_rg(rg_path, query, worktree, opts) do
    exclude_args = Enum.flat_map(@rg_exclude_globs, fn g -> ["--glob", "!#{g}"] end)
    base_args = [
      "--json",
      "--line-number",
      "--smart-case",
      "--context", "5",                # provide 5 lines of context
      "--max-count", "5",              # max 5 matches per file
      "--max-filesize", "500K",        # skip files larger than 500KB
      "--no-binary",                   # skip binary files
      "--max-depth", "20"              # prevent runaway depth
    ]

    task = Task.async(fn ->
      System.cmd(
        rg_path,
        base_args ++ exclude_args ++ [query, "."],
        cd: worktree,
        stderr_to_stdout: true
      )
    end)

    case Task.yield(task, Keyword.get(opts, :timeout, 30_000)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        cond do
          exit_code == 0 ->
            results = parse_rg_json(output) |> Enum.take(@rg_max_results)
            telemetry(%{action: :search_success, count: length(results)})
            {:ok, results}
          exit_code == 1 ->
            telemetry(%{action: :search_success, count: 0})
            {:ok, []}
          true ->
            telemetry(%{action: :search_failed, exit_code: exit_code})
            {:error, :transient, "ripgrep failed with code #{exit_code}"}
        end
      nil ->
        telemetry(%{action: :search_timeout, status: :timeout})
        {:error, :transient, :timeout}
      {:exit, reason} ->
        telemetry(%{action: :search_error, error: inspect(reason)})
        {:error, :hard, reason}
    end
  rescue
    e ->
      telemetry(%{action: :search_error, error: Exception.message(e)})
      {:error, :transient, Exception.message(e)}
  end

  defp search_with_grep(query, worktree, opts) do
    Logger.info("TextEngine: 'rg' not found, falling back to 'grep'")
    
    # Build grep exclude arguments
    exclude_args = Enum.flat_map(@rg_exclude_globs, fn g ->
      cond do
        String.contains?(g, "/") -> ["--exclude=#{g}", "--exclude-dir=#{g}"]
        String.ends_with?(g, [".md", ".txt", ".json", ".lock", ".beam", ".pyc", ".class", ".o", ".so", ".deb", ".rpm", ".whl", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg", ".mp4", ".mp3", ".zip", ".tar", ".gz", ".rar"]) -> ["--exclude=#{g}"]
        String.contains?(g, "*") -> ["--exclude=#{g}"]
        true -> ["--exclude-dir=#{g}", "--exclude=#{g}"]
      end
    end)

    task = Task.async(fn ->
      System.cmd("grep", ["-rn"] ++ exclude_args ++ [query, "."], cd: worktree, stderr_to_stdout: true)
    end)

    case Task.yield(task, Keyword.get(opts, :timeout, 30_000)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        cond do
          exit_code == 0 ->
            # Very basic parsing for fallback grep
            results = output
                      |> String.split("\n", trim: true)
                      |> Enum.map(fn line ->
                        # naive parsing: "file:line:content"
                        parts = String.split(line, ":", parts: 3)
                        if length(parts) == 3 do
                          [file, lno, content] = parts
                          case Integer.parse(lno) do
                            {lno_int, _} ->
                              %SearchResult{
                                source: :text_engine,
                                content: "File: #{file} (Line: #{lno_int})\n#{content}",
                                score: 0.3, # lower score for less context
                                metadata: %{file_path: file, line: lno_int}
                              }
                            :error ->
                              nil
                          end
                        else
                          nil
                        end
                      end)
                      |> Enum.reject(&is_nil/1)
                      |> Enum.reject(fn r -> 
                        path = r.metadata.file_path
                        String.contains?(path, "agent_message.md") or String.contains?(path, ".acn/")
                      end)
                      |> Enum.take(@rg_max_results)
                      
            telemetry(%{action: :search_success, count: length(results)})
            {:ok, results}
          exit_code == 1 ->
            telemetry(%{action: :search_success, count: 0})
            {:ok, []}
          true ->
            telemetry(%{action: :search_failed, exit_code: exit_code})
            {:error, :transient, "grep failed with code #{exit_code}"}
        end
      nil ->
        telemetry(%{action: :search_timeout, status: :timeout})
        {:error, :transient, :timeout}
      {:exit, reason} ->
        telemetry(%{action: :search_error, error: inspect(reason)})
        {:error, :hard, reason}
    end
  rescue
    e ->
      telemetry(%{action: :search_error, error: Exception.message(e)})
      {:error, :transient, Exception.message(e)}
  end

  # The parse_grep_output function was removed as its logic was inlined into search_with_grep.

  @impl true
  def validate_query(query) do
    if String.trim(query) == "" do
      {:error, :empty_query}
    else
      :ok
    end
  end

  @impl true
  def telemetry(data) do
    EventMonitor.emit([:procoder, :search, :adapter], %{}, data)
  end

  # --- Internal Helpers ---

  defp parse_rg_json(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "match", "data" => match_data}} -> [match_data]
        {:ok, %{"type" => "context", "data" => context_data}} -> [context_data]
        _ -> []
      end
    end)
    |> Enum.group_by(fn d -> get_in(d, ["path", "text"]) end)
    |> Enum.flat_map(fn {path, lines} ->
      if String.contains?(path, "agent_message.md") or String.contains?(path, ".acn/") do
        []
      else
        lines
        |> Enum.sort_by(fn d -> d["line_number"] end)
        |> cluster_lines()
        |> Enum.take(5) # Max 5 chunks per file
        |> Enum.map(fn chunk -> format_chunk(path, chunk) end)
      end
    end)
    |> Enum.take(@rg_max_results)
  end

  defp cluster_lines(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case acc do
        [] -> [[line]]
        [current_chunk | rest] ->
          last_line = List.last(current_chunk)
          # Use 2 for gap to merge lines that are close (e.g. separated by only one line)
          if line["line_number"] <= last_line["line_number"] + 1 do
            [current_chunk ++ [line] | rest]
          else
            [[line], current_chunk | rest]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn chunk -> Enum.uniq_by(chunk, & &1["line_number"]) end)
  end


  defp format_chunk(path, lines) do
    first_ln = List.first(lines)["line_number"]
    last_ln = List.last(lines)["line_number"]
    content = Enum.map_join(lines, "", fn d -> d["lines"]["text"] end)

    %SearchResult{
      source: :text_engine,
      content: "File: #{path} (Lines: #{first_ln}-#{last_ln})\n#{content}",
      score: 0.5,
      metadata: %{
        file_path: path,
        start_line: first_ln,
        end_line: last_ln
      }
    }
  end
end
