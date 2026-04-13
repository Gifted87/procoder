defmodule ProCoder.SupervisionTree.RootSupervisor.Planner.PlannerSupervisor do
  @moduledoc """
  The PlannerSupervisor manages the ProCoder Planner Domain lifecycle.
  It orchestrates the PersistenceEngine, FailureRemediator, and PlannerGenServer processes,
  ensuring ordered initialization, fault isolation, and resilient recovery.
  """

  use Supervisor
  require Logger

  @doc """
  Starts the PlannerSupervisor process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, "planner_supervisor_#{session_id}"}}

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    
    children = [
      # 1. PersistenceEngine: Bedrock of planner state.
      %{
        id: ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine,
        start: {ProCoder.Planner.LogicEngine.DAGOrchestrator.Persistence.PersistenceEngine, :start_link, [[session_id: session_id]]},
        restart: :permanent,
        shutdown: 5000
      },
      # 2. FailureRemediator: Self-healing compensation subgraph manager.
      %{
        id: ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator,
        start: {ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.RecoveryLogic.FailureRemediator, :start_link, [[session_id: session_id]]},
        restart: :permanent,
        shutdown: 5000
      },
      # 3. DispatchCoordinator: Topological execution orchestrator.
      %{
        id: ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator,
        start: {ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.DispatchLogic.DispatchCoordinator, :start_link, [[session_id: session_id]]},
        restart: :permanent,
        shutdown: 5000
      },
      # 4. PlannerGenServer: Central orchestrator for DAG planning.
      # Depends on PersistenceEngine; initialization order managed by the supervisor tree.
      %{
        id: ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer,
        start: {ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer, :start_link, [[session_id: session_id]]},
        restart: :permanent,
        shutdown: 5000
      }
    ]

    # Strategy: :one_for_one ensures granular recovery of failing planner components.
    # Intensity: 10 restarts per 60 seconds provides sufficient buffer for transient issues.
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 10, max_seconds: 60)
  end
end
