defmodule ProCoder.SupervisionTree.RootSupervisor.CoreSupervisor do
  @moduledoc """
  Primary sub-supervisor for the Core domain within the ProCoder system.
  
  Orchestrates the foundational components (SessionManager, Registry, HistoryStackEngine)
  with strict high-availability and fault-tolerance mandates.
  """

  use Supervisor
  require Logger

  @telemetry_prefix [:procoder, :supervision_tree, :core_supervisor]

  @doc """
  Starts the CoreSupervisor.
  """
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # 1. Registry (Must be started first for discovery)
      %{
        id: ProCoder.Registry,
        start: {Registry, :start_link, [[keys: :unique, name: ProCoder.Registry]]},
        restart: :permanent,
        shutdown: 5000
      },
      # 2. HistoryStackEngine (Cognitive persistence)
      %{
        id: ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine,
        start: {ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine, :start_link, [[session_id: "global_history"]]},
        restart: :permanent,
        shutdown: 5000
      },
      # 3. SessionManager (Swarm entry point)
      %{
        id: ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager,
        start: {ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager, :start_link, [[]]},
        restart: :permanent,
        shutdown: 10_000
      }
    ]

    # Enforcement: :one_for_one strategy ensures local containment of failures.
    # Max restarts: 10 per 60 seconds as per specification.
    opts = [
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(@telemetry_prefix ++ [event], %{timestamp: DateTime.utc_now()}, metadata)
  end

  @doc """
  Handle process termination to ensure telemetry logging and quarantine state triggers.
  """
  def handle_child_termination(child_id, reason) do
    emit_telemetry(:child_terminated, %{child_id: child_id, reason: inspect(reason)})
    Logger.error("Core domain child #{inspect(child_id)} terminated: #{inspect(reason)}")
  end
end
