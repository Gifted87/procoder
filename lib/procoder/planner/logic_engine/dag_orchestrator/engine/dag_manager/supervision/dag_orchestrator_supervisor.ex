defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.Supervision.DAGOrchestratorSupervisor do
  @moduledoc """
  The apex supervisor for a single DAG orchestrator planning session.

  Manages the lifecycle of:
  1. PersistenceEngine (Durability)
  2. GraphEngineServer (DAGEngine / State)
  3. DispatchCoordinator (Scheduler)
  4. FailureRemediator (RecoveryManager)

  Enforces ordered startup and granular fault isolation using a :one_for_one strategy.
  """

  use Supervisor
  require Logger

  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.GraphEngineServer
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator
  alias ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator
  alias ProCoder.Planner.DAG.Manager.Requirements

  @doc """
  Starts the DAGOrchestratorSupervisor for a specific session.
  """
  def start_link(session_id) when is_binary(session_id) do
    Supervisor.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @impl true
  def init(session_id) do
    # Pre-flight environment check
    case Requirements.init!() do
      :ok ->
        children = [
          # Persistence must be live first to re-hydrate state
          {PersistenceEngine, [session_id: session_id]},
          # Graph Engine holds the primary DAG state
          {GraphEngineServer, [session_id: session_id]},
          # Coordinator schedules tasks based on graph state
          {DispatchCoordinator, [session_id: session_id]},
          # Remediation manager triggers compensation subgraphs on failure
          {FailureRemediator, [session_id: session_id]}
        ]

        # :one_for_one ensures isolation: one component crash does not cascade.
        # Max restart intensity: 10 restarts / 60 seconds (as per blueprint).
        Supervisor.init(children,
          strategy: :one_for_one,
          max_restarts: 10,
          max_seconds: 60
        )

      _ ->
        Logger.emergency("DAGOrchestratorSupervisor failed to start due to environment mismatch.")
        :ignore
    end
  end

  @doc """
  Telemetry wrapper for child process termination monitoring.
  """
  def handle_child_termination(session_id, child_module, reason) do
    :telemetry.execute(
      [:procoder, :planner, :supervisor, :child_terminated],
      %{reason: inspect(reason)},
      %{session_id: session_id, module: child_module}
    )
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "supervisor_#{session_id}"}}
end
