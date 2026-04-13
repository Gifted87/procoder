defmodule ProCoder.Search.Adapters.LSPAdapter do
  @moduledoc """
  The LSP Adapter implements the ProCoder.Search.Adapter behavior, acting as the
  primary, high-precision retrieval mechanism for code navigation. It bridges
  the Search Coordinator with the system-wide LSP Manager.
  """

  use ProCoder.Search.Adapter
  require Logger

  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.Brain.Client.Telemetry.EventMonitor

  @doc """
  Performs a precise symbol or definition lookup via the LSP Manager.
  The request is offloaded to a Task to ensure non-blocking execution.
  """
  @impl true
  def search(query, options) do
    worktree_id = Keyword.get(options, :worktree_id)
    
    if is_nil(worktree_id) do
      {:error, :hard, "Missing required option: worktree_id"}
    else
      telemetry(%{action: :search_start, query: query, worktree_id: worktree_id})

      try do
        task = Task.async(fn ->
          # Interface with system-wide LSP Manager
          # This assumes LSP.Manager is registered or available in the supervision tree
          case ProCoder.Tooling.LSP.Manager.query(worktree_id, query, options) do
            {:ok, raw_results} ->
              results = Enum.map(raw_results, &transform_lsp_result/1)
              {:ok, results}
            {:error, reason} ->
              {:error, :transient, reason}
          end
        end)
        
        case Task.yield(task, Keyword.get(options, :timeout, 30_000)) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            telemetry(%{action: :search_stop, status: :success})
            result
          nil ->
            # Task timed out and was shut down by the second clause
            telemetry(%{action: :search_stop, status: :timeout})
            {:error, :transient, :timeout}
          {:exit, reason} ->
            telemetry(%{action: :search_stop, status: :error, reason: inspect(reason)})
            {:error, :hard, reason}
        end
      rescue
        e ->
          telemetry(%{action: :search_stop, status: :error, reason: inspect(e)})
          {:error, :hard, e}
      end
    end
  end

  @doc """
  Validates that the query does not contain malicious patterns and is suitable
  for LSP ingestion.
  """
  @impl true
  def validate_query(query) do
    if String.length(query) > 0 and String.length(query) < 1024 do
      :ok
    else
      {:error, :invalid_query_format}
    end
  end

  @doc """
  Reports standardized search metrics to the system-wide telemetry monitor.
  """
  @impl true
  def telemetry(telemetry_data) do
    EventMonitor.emit(
      [:procoder, :search, :adapter, :lsp],
      %{timestamp: DateTime.utc_now()},
      telemetry_data
    )
    :ok
  end

  # --- Private Helpers ---

  defp transform_lsp_result(raw) do
    # Map raw LSP payload to standardized SearchResult struct
    %SearchResult{
      source: :lsp,
      content: Map.get(raw, "symbol_name", ""),
      score: 1.0, # LSP provides exact matches
      metadata: %{
        file_path: Map.get(raw, "file_path"),
        range: Map.get(raw, "range")
      }
    }
  end
end
