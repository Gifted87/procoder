defmodule ProCoder.Search.Coordinator.Logic.SearchErrorHandler do
  @moduledoc """
  The SearchErrorHandler module orchestrates the 'Gradient of Precision' search cascade.
  It acts as a stateless decision-making engine that manages execution flow,
  graceful degradation across search layers (LSP, Text, Vector), and failure recovery.
  """

  require Logger

  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.Search.Coordinator.Telemetry

  @type adapter_result :: {:ok, [SearchResult.t()]} | {:error, :transient | :hard, term()}
  @type cascade_state :: %{
    results: [SearchResult.t()],
    degradation_depth: integer(),
    failures: list(),
    session_id: binary(),
    options: keyword()
  }

  @doc """
  Orchestrates the search cascade across an ordered chain of search adapters.
  
  - query: The string query to process.
  - chain: A list of modules implementing ProCoder.Search.Adapter.
  - state: Initial or current cascade state.
  """
  @spec handle_cascade(String.t(), [module()], cascade_state()) :: [SearchResult.t()]
  def handle_cascade(query, chain, state) do
    do_handle_cascade(query, chain, state)
  end

  # --- Private Cascade Logic ---

  defp do_handle_cascade(_query, [], state), do: state.results

  defp do_handle_cascade(query, [adapter | rest], state) do
    start_time = System.monotonic_time(:microsecond)
    
    # 1. Execute layer
    result = execute_adapter(adapter, query, state.options)
    
    end_time = System.monotonic_time(:microsecond)
    duration = System.convert_time_unit(end_time - start_time, :native, :microsecond)

    # 2. Evaluate result and orchestrate next steps
    case result do
      {:ok, layer_results} when layer_results != [] ->
        # Exact/Valid match found; log telemetry and return aggregated results
        emit_layer_telemetry(state.session_id, adapter, :success, duration, length(layer_results))
        state.results ++ layer_results

      {:ok, []} ->
        # Empty result; trigger degradation
        emit_layer_telemetry(state.session_id, adapter, :success, duration, 0)
        do_handle_cascade(query, rest, %{state | degradation_depth: state.degradation_depth + 1})

      {:error, :transient, reason} ->
        # Recoverable error; log and proceed
        Logger.warning("Transient error in #{adapter}: #{inspect(reason)}")
        emit_layer_telemetry(state.session_id, adapter, :failure, duration, 0, reason)
        do_handle_cascade(query, rest, %{state | degradation_depth: state.degradation_depth + 1})

      {:error, :hard, reason} ->
        # Irrecoverable error; abandon layer and proceed
        Logger.error("Hard error in #{adapter}: #{inspect(reason)}")
        emit_layer_telemetry(state.session_id, adapter, :failure, duration, 0, reason)
        do_handle_cascade(query, rest, %{state | degradation_depth: state.degradation_depth + 1})
    end
  end

  defp execute_adapter(adapter, query, options) do
    session_id = Keyword.get(options, :session_id, "default")
    if !valid_worktree_context?(session_id) do
      {:error, :hard, :unauthorized_context}
    else
      adapter.search(query, options)
    end
  end

  defp valid_worktree_context?(session_id) do
    # Verify context isolation logic by checking with the SessionManager
    ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager.authorized?(session_id)
  end

  defp emit_layer_telemetry(session_id, adapter, status, duration, count, error_type \\ nil) do
    adapter_name = adapter |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
    
    Telemetry.emit_layer_result(session_id, adapter_name, status, %{
      duration: duration,
      result_count: count,
      error_type: error_type
    })
  end
end
