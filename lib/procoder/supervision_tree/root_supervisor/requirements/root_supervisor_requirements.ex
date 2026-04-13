defmodule ProCoder.SupervisionTree.RootSupervisor.Requirements do
  @moduledoc """
  Defines the supervision tree specifications for the ProCoder root supervisor.
  
  This module acts as the contract for the system's root supervision tree, 
  defining restart strategies, shutdown timeouts, and domain-specific 
  supervision mandates to ensure system-wide fault isolation and high availability.
  
  Adheres to Pillar VII requirements for OTP supervision tree principles.
  """

  @type supervisor_strategy :: :one_for_one | :one_for_all | :rest_for_one
  @type restart_strategy :: :permanent | :transient | :temporary
  @type child_spec :: %{
    id: atom(),
    start: {module(), atom(), list()},
    restart: restart_strategy(),
    shutdown: pos_integer() | :infinity
  }

  @doc """
  Returns the child specification for the ProCoder Core Domain.
  The Core domain is the foundation for state management and session orchestration.
  """
  @spec core_domain_spec() :: list(child_spec())
  def core_domain_spec do
    [
      %{
        id: ProCoder.Repo,
        start: {ProCoder.Repo, :start_link, [[]]},
        restart: :permanent,
        shutdown: 5000
      },
      %{
        id: ProCoder.Registry,
        start: {Registry, :start_link, [[keys: :unique, name: ProCoder.Registry]]},
        restart: :permanent,
        shutdown: 5000
      },
      %{
        id: ProCoder.SessionManager,
        start: {ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager, :start_link, [[]]},
        restart: :permanent,
        shutdown: 10_000
      }
    ]
  end

  @doc """
  Returns the child specification for the ProCoder Planner Domain.
  Responsible for DAG orchestration and failure recovery.
  """
  @spec planner_domain_spec() :: list(child_spec())
  def planner_domain_spec do
    [
      %{
        id: ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.Supervision.DAGOrchestratorSupervisor,
        start: {ProCoder.Planner.LogicEngine.DAGOrchestrator.Engine.DAGManager.Supervision.DAGOrchestratorSupervisor, :start_link, [[]]},
        restart: :permanent,
        shutdown: 5000
      }
    ]
  end

  @doc """
  Returns the child specification for the ProCoder Brain Domain.
  Manages external connectivity, cognitive persistence, and rate regulation.
  """
  @spec brain_domain_spec() :: list(child_spec())
  def brain_domain_spec do
    [
      %{
        id: ProCoder.Brain.RateLimiter,
        start: {ProCoder.Brain.RateLimiter, :start_link, [[]]},
        restart: :permanent,
        shutdown: 5000
      },
      %{
        id: ProCoder.Brain.MemoryStore.Supervisor,
        start: {ProCoder.Brain.MemoryStore.Supervisor, :start_link, [[]]},
        restart: :transient,
        shutdown: 10_000
      },
      %{
        id: ProCoder.Brain.Client.Engine,
        start: {ProCoder.Brain.Client.Engine, :start_link, [[]]},
        restart: :permanent,
        shutdown: 5000
      }
    ]
  end

  @doc """
  Returns the child specification for the ProCoder Actuator Domain.
  Handles I/O, sandboxed execution, and command routing.
  """
  @spec actuator_domain_spec() :: list(child_spec())
  def actuator_domain_spec do
    [
      %{
        id: ProCoder.UI.RoutingLayer.CommandRouter,
        start: {ProCoder.UI.RoutingLayer.CommandRouter, :start_link, [[]]},
        restart: :permanent,
        shutdown: 5000
      },
      %{
        id: ProCoder.Actuator.PortWrapper,
        start: {ProCoder.Actuator.PortWrapper, :start_link, [[]]},
        restart: :transient,
        shutdown: 5000
      }
    ]
  end
end
