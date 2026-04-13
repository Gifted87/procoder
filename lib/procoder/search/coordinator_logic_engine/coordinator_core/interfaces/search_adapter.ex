defmodule ProCoder.Search.Adapter do
  @moduledoc """
  The `ProCoder.Search.Adapter` behavior defines the polymorphic contract for all
  search retrieval backends (LSP, Text Engine, Vector Store) within the
  'Gradient of Precision' search cascade.

  All implementations must ensure non-blocking, asynchronous execution and adhere
  to standardized result formatting and telemetry reporting.
  """

  alias ProCoder.Core.Types.SearchResult

  @type query :: String.t()
  @type options :: keyword()
  @type adapter_error :: {:error, :transient | :hard, term()}

  @doc """
  The primary execution callback for performing a search.
  
  Must accept a string query and a keyword option list.
  Implementations must return `{:ok, [SearchResult.t()]}` or an error tuple.
  Execution must be performed in a non-blocking manner (e.g., via Task.async).
  """
  @callback search(query(), options()) :: {:ok, [SearchResult.t()]} | adapter_error()

  @doc """
  A preemptive validation hook to check query integrity (e.g., regex syntax
  validation, JSON schema validation for VectorStore) before the backend
  is tasked with processing.
  """
  @callback validate_query(query()) :: :ok | {:error, term()}

  @doc """
  Optional hook for reporting standardized observability metrics.
  
  Implementations are encouraged to emit telemetry events for:
  - `[:procoder, :search, :adapter, :start]`
  - `[:procoder, :search, :adapter, :stop]`
  """
  @callback telemetry(telemetry_data :: map()) :: :ok

  @doc """
  Convenience macro to ensure the behavior is correctly applied.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour ProCoder.Search.Adapter
    end
  end
end
