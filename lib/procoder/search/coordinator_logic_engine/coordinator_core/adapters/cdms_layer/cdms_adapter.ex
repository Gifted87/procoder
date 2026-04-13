defmodule ProCoder.Search.Adapters.CDMSAdapter do
  @moduledoc """
  The Adapter linking ProCoder's Search Coordinator to the Cognitive Digital Modelling System (CDMS).
  Replaces VectorStoreAdapter for high-level semantic, brainstorming, and graph queries.
  """
  use ProCoder.Search.Adapter
  require Logger

  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.Brain.Client.Telemetry.EventMonitor

  @impl true
  def search(query, opts) do
    Task.async(fn ->
      :telemetry.span([:procoder, :search, :cdms], %{query: query}, fn ->
        result = execute_unified_query(query, opts)
        {result, %{query: query}}
      end)
    end)
    |> Task.await(Keyword.get(opts, :timeout, 120_000))
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
    EventMonitor.emit([:procoder, :search, :cdms_store], %{}, data)
  end

  # --- Private Implementation ---

  defp execute_unified_query(query, opts) do
    # Only supply reasoning_mode if provided, defaults to normal behavior otherwise.
    payload = %{
      query: query,
      threshold: Keyword.get(opts, :threshold, 0.4),
      max_results: Keyword.get(opts, :max_results, 5)
    }
    
    payload = 
      case Keyword.get(opts, :reasoning_mode) do
        nil -> payload
        mode -> Map.put(payload, :reasoning_mode, mode)
      end
      
    payload = 
      case Keyword.get(opts, :mode) do
        nil -> payload
        mode -> Map.put(payload, :mode, mode)
      end

    url = "http://localhost:5115/api/v1/query/unified"
    
    # Simple HTTP post (using the built-in HTTP client if available, but assuming HTTPoison due to standard mix ecosystem)
    # Using :httpc as a fallback ensures no missing dependencies if HTTPoison isn't there, 
    # but we will try with Jason directly.
    json_body = Jason.encode!(payload)
    headers = [{'Content-Type', 'application/json'}]

    # In Elixir we can use standard erlang :httpc
    request = {String.to_charlist(url), headers, 'application/json', json_body}
    
    case :httpc.request(:post, request, [{:timeout, 120_000}], []) do
      {:ok, {{_, 200, _}, _headers, response_body}} ->
        # PASS RAW: No validation, no transformation. Just give the LLM the raw bytes.
        raw_json = to_string(response_body)
        
        result = %SearchResult{
          source: :cdms,
          content: raw_json,
          score: 1.0,
          metadata: %{raw: true}
        }
        
        {:ok, [result]}

      {:ok, {{_, status, _}, _, _}} ->
        Logger.error("CDMS query failed with status #{status}")
        {:error, :transient, "CDMS HTTP returned #{status}"}

      {:error, reason} ->
        Logger.error("Failed to connect to CDMS layer: #{inspect(reason)}")
        {:error, :transient, "Could not connect to CDMS on port 5115"}
    end
  rescue
    e ->
      Logger.error("CDMS Adapter crash: #{inspect(e)}")
      {:error, :transient, :panic}
  end

  defp transform_node(node) do
    score = Map.get(node, "score", 0.0)
    identity = Map.get(node, "identity", %{})
    path = Map.get(identity, "path", "unknown_path")

    %SearchResult{
      source: :cdms,
      content: Jason.encode!(node, pretty: true),
      score: score,
      metadata: %{
        path: path
      }
    }
  end
end
