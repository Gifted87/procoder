defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Lifecycle.TaskState do
  @moduledoc """
  The Task State Machine module for the ProCoder DAG Orchestrator.
  
  Manages the lifecycle transitions of TaskNodes, ensuring structural integrity,
  telemetry emission, and triggering of remediation subgraphs upon failure.
  """

  require Logger
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Types
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Types.TaskNode

  @type status :: Types.status()
  @type transition_error :: :invalid_transition | :invalid_payload | term()

  @doc """
  Executes a state transition for a TaskNode.
  
  Validates the transition, updates the node metadata, emits telemetry,
  and triggers recovery logic if the state is transitioned to :failed.
  """
  @spec transition(TaskNode.t(), status()) :: {:ok, TaskNode.t()} | {:error, transition_error()}
  def transition(node, new_status) do
    if is_valid_transition?(node.status, new_status) do
      try do
        updated_node = perform_transition(node, new_status)
        
        emit_telemetry(updated_node, node.status, new_status)
        
        if new_status == :failed do
          trigger_recovery(updated_node)
        end
        
        {:ok, updated_node}
      rescue
        e ->
          Logger.error("Unexpected error during transition for node #{node.id}: #{Exception.message(e)}")
          {:error, :unexpected_error}
      end
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Determines if a transition between two states is permitted.
  """
  @spec is_valid_transition?(status(), status()) :: boolean()
  def is_valid_transition?(current, next) when current == next, do: false
  def is_valid_transition?(:pending, :running), do: true
  def is_valid_transition?(:running, :completed), do: true
  def is_valid_transition?(:running, :failed), do: true
  def is_valid_transition?(:pending, :failed), do: true
  def is_valid_transition?(_current, _next), do: false

  @doc """
  Returns a list of allowed next states for a given status.
  """
  @spec get_allowed_transitions(status()) :: [status()]
  def get_allowed_transitions(:pending), do: [:running, :failed]
  def get_allowed_transitions(:running), do: [:completed, :failed]
  def get_allowed_transitions(:completed), do: []
  def get_allowed_transitions(:failed), do: []

  # --- Internal Logic ---

  defp perform_transition(node, new_status) do
    metadata = Map.merge(node.metadata, %{
      transitioned_at: DateTime.utc_now(),
      previous_status: node.status
    })
    
    %{node | status: new_status, metadata: metadata}
  end

  defp emit_telemetry(node, old_status, new_status) do
    :telemetry.execute(
      [:procoder, :planner, :task, :transition],
      %{duration_ms: 0},
      %{
        task_id: node.id,
        from: old_status,
        to: new_status
      }
    )
  end

  defp trigger_recovery(node) do
    Logger.info("Transitioned node #{node.id} to :failed. Triggering recovery manager.")
    session_id = Map.get(node.metadata, :session_id)

    if session_id do
      remediator_ref = {:via, Registry, {ProCoder.Registry, "remediator_#{session_id}"}}
      ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator.remediate(
        remediator_ref,
        node.id,
        Map.get(node.metadata, :failure_reason, :unknown),
        Graph.new(),
        %{}
      )
    else
      Logger.warning("[TaskState] Cannot trigger recovery for node #{node.id}: no session_id in metadata")
    end
  end
end
