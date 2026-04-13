defmodule ProCoder.Tooling.LSP.Manager do
  @moduledoc """
  The LSP Manager orchestrates multiple language server instances.
  It acts as a router for incoming JSON-RPC queries from the Search Coordinator.
  """

  use GenServer
  require Logger

  @doc """
  Starts the LSP Manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queries a specific language server.
  Accepts an optional `worktree_root` option to resolve the search path.
  """
  def query(worktree_id, query_text, opts \\ []) do
    GenServer.call(__MODULE__, {:query, worktree_id, query_text, opts}, 15_000)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_call({:query, worktree_id, query_text, opts}, _from, state) do
    Logger.info("LSP Query (Symbol Lookup) for #{worktree_id}: #{query_text}")
    
    # 1. Build exclusion arguments from CodeGraphEngine
    exclusions = ProCoder.Search.CodeGraphEngine.directory_blacklist()
    
    # 2. Determine search pattern. 
    # Current improvement: Always anchor to the beginning of the line for definitions
    # to avoid matching words inside comments/strings.
    definition_keywords_group = "(defmodule|def|defp|defmacro|defstruct|defprotocol|defimpl)"
    definition_keywords_regex = ~r/^\s*#{definition_keywords_group}\b/
    
    pattern = 
      if Regex.match?(definition_keywords_regex, query_text) do
        # If it already starts with a keyword, just ensure it's anchored
        "^[ \\t]*#{String.trim_leading(query_text)}"
      else
        "^[ \\t]*#{definition_keywords_group}[ \\t]+#{Regex.escape(query_text)}\\b"
      end

    # 3. Resolve worktree_path: prefer explicit worktree_root from opts over legacy tmp convention
    worktree_path = Keyword.get(opts, :worktree_root) || "/tmp/procoder_worktrees/#{worktree_id}"
    
    # 4. Prefer ripgrep for performance if available
    {cmd, args} = 
      case System.find_executable("rg") do
        path when not is_nil(path) ->
          exclude_args = Enum.flat_map(exclusions, fn d -> ["-g", "!#{d}"] end)
          {path, [
            "--json", 
            "--smart-case", 
            "--multiline", 
            "--max-count", "5",        # Max 5 matches per file
            pattern, 
            "--glob", "*.ex", 
            "--glob", "*.exs"
          ] ++ exclude_args ++ ["."]}
        
        nil ->
          exclude_args = Enum.flat_map(exclusions, fn d -> ["--exclude-dir=#{d}"] end)
          {"grep", ["-rE", "-n", "--max-count=10", pattern, "--include=*.ex", "--include=*.exs"] ++ exclude_args ++ ["."]}
      end

    Logger.debug("LSP Syntax Check: cd #{worktree_path} && #{cmd} #{Enum.join(args, " ")}")

    case System.cmd(cmd, args, cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} ->
        results = 
          if String.contains?(cmd, "rg") do
            parse_rg_output(output, query_text)
          else
            parse_grep_output(output, query_text)
          end
          
        {:reply, {:ok, results}, state}
        
      {_output, exit_code} when exit_code in [1, 2] ->
        # 1 means no match, 2 might mean error - we return empty to avoid crashing cascade
        {:reply, {:ok, []}, state}
        
      {error_out, code} ->
        Logger.error("LSP syntax lookup failed (Exit #{code}): #{error_out}")
        {:reply, {:ok, []}, state}
    end
  end

  # --- Internal Parsers ---

  defp parse_rg_output(output, query_text) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(100)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "match", "data" => %{"path" => %{"text" => path}, "line_number" => lno, "lines" => %{"text" => content}}}} ->
          [%{
            "symbol_name" => query_text,
            "file_path" => path,
            "range" => %{"start" => %{"line" => lno}, "end" => %{"line" => lno}},
            "content" => String.trim(content)
          }]
        _ -> []
      end
    end)
  end

  defp parse_grep_output(output, query_text) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(100)
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 3) do
        [file, lno_str, content] ->
          case Integer.parse(lno_str) do
            {lno, _} ->
              %{
                "symbol_name" => query_text,
                "file_path" => file,
                "range" => %{"start" => %{"line" => lno}, "end" => %{"line" => lno}},
                "content" => String.trim(content)
              }
            :error -> nil
          end
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
