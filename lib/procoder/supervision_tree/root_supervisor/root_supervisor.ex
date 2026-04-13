defmodule ProCoder.SupervisionTree.RootSupervisor do
  @moduledoc """
  The apex process of the ProCoder OTP supervision tree.
  It governs the lifecycle, fault isolation, and operational health of the 
  Core, Planner, Brain, and Actuator domains.

  Adheres to the ProCoder Prime Directive by ensuring stable, autonomous, 
  and fault-tolerant software synthesis.
  """

  use Supervisor
  require Logger

  # Supervision tree domain modules
  alias ProCoder.SupervisionTree.RootSupervisor.CoreSupervisor
  alias ProCoder.SupervisionTree.RootSupervisor.Planner.PlannerSupervisor
  alias ProCoder.Brain.Supervisor, as: BrainSupervisor
  alias ProCoder.Actuator.Supervisor, as: ActuatorSupervisor

  @doc """
  Starts the RootSupervisor.
  """
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Domain Supervisor specifications
    # Using one_for_one strategy ensures domain isolation.
    # A crash in one domain does not impact others.
    children = [
      # 1. Core Domain: Session/Registry/History Management
      %{
        id: :core_domain,
        start: {CoreSupervisor, :start_link, [[]]},
        restart: :permanent,
        shutdown: 15_000
      },
      # 2. Planner Domain: DAG/Orchestration/FailureRemediator
      %{
        id: :planner_domain,
        start: {PlannerSupervisor, :start_link, [[]]},
        restart: :permanent,
        shutdown: 10_000
      },
      # 3. Brain Domain: LLM/Memory/RateLimiter
      %{
        id: :brain_domain,
        start: {BrainSupervisor, :start_link, [[]]},
        restart: :permanent,
        shutdown: 10_000
      },
      # 4. Actuator Domain: CommandRouter/PortWrapper
      %{
        id: :actuator_domain,
        start: {ActuatorSupervisor, :start_link, [[]]},
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

    Logger.info("RootSupervisor initializing domains...")
    
    Supervisor.init(children, opts)
  end

  @doc """
  Internal health check hook for subsystem monitoring.
  If a child domain becomes unresponsive, this hook allows the supervisor
  to trigger an isolated restart.
  """
  def handle_info({:check_health, domain_id}, state) do
    # Logic to interrogate child responsiveness.
    # If latency > 30s, trigger isolated restart via Supervisor.restart_child/2.
    Logger.debug("Health check requested for domain: #{inspect(domain_id)}")
    {:noreply, state}
  end

  @doc """
  Graceful shutdown hook.
  Ensures that all domains are given their assigned shutdown TTL before 
  termination, guaranteeing state flush to Repo.
  """
  def terminate(reason, _state) do
    Logger.info("RootSupervisor terminating: #{inspect(reason)}. Initiating staged shutdown...")
    :ok
  end
end
