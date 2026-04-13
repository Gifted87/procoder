defmodule ProCoder.SupervisionTree.RootSupervisor.Monitoring.HealthCheck do
  @moduledoc """
  Autonomic health monitoring service for the ProCoder supervision tree.
  Provides real-time observability, telemetry, and emergency isolation for
  critical system domains (Core, Planner, Brain, Actuator).
  """

  use GenServer
  require Logger

  @type health_status :: :healthy | :unhealthy | :degraded
  @type domain_status :: %{
          status: health_status(),
          last_checked: DateTime.t(),
          failure_count: non_neg_integer()
        }


  @telemetry_prefix [:procoder, :supervision_tree, :health_check]

  # --- API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Public diagnostic API for TUI dashboarding.
  Returns an aggregate health status of all monitored domains.
  """
  def get_system_status do
    GenServer.call(__MODULE__, :get_system_status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    interval = Application.get_env(:procoder, :health_check)[:interval_ms] || 5_000
    Process.send_after(self(), :check_cycle, interval)

    {:ok, %{
      domains: %{
        core: %{status: :healthy, last_checked: DateTime.utc_now(), failure_count: 0},
        planner: %{status: :healthy, last_checked: DateTime.utc_now(), failure_count: 0},
        brain: %{status: :healthy, last_checked: DateTime.utc_now(), failure_count: 0},
        actuator: %{status: :healthy, last_checked: DateTime.utc_now(), failure_count: 0}
      },
      history: [],
      interval: interval
    }}
  end

  @impl true
  def handle_call(:get_system_status, _from, state) do
    {:reply, state.domains, state}
  end

  @impl true
  def handle_info(:check_cycle, state) do
    # Run checks asynchronously
    Enum.each(state.domains, fn {domain, _} ->
      Task.start(fn -> perform_domain_check(domain) end)
    end)

    Process.send_after(self(), :check_cycle, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:check_result, domain, result}, state) do
    new_domains = update_domain_status(state.domains, domain, result)
    
    # Check for escalation
    if new_domains[domain].failure_count >= 5 do
      trigger_emergency_isolation(domain)
    end

    emit_telemetry(new_domains)
    
    {:noreply, %{state | domains: new_domains}}
  end

  # --- Internal Logic ---

  defp perform_domain_check(domain) do
    # Domain specific logic using Registry lookups to find PIDs
    result = case domain do
      :core -> check_core()
      :planner -> check_planner()
      :brain -> check_brain()
      :actuator -> check_actuator()
    end

    send(self(), {:check_result, domain, result})
  end

  defp check_core, do: check_registry_and_process(ProCoder.Registry, ProCoder.SessionManager)
  defp check_planner, do: check_registry_and_process(ProCoder.Registry, ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer)
  defp check_brain, do: check_registry_and_process(ProCoder.Registry, ProCoder.Brain.RateLimiter)
  defp check_actuator, do: check_registry_and_process(ProCoder.Registry, ProCoder.UI.RoutingLayer.CommandRouter)

  defp check_registry_and_process(registry, module) do
    case Registry.lookup(registry, module) do
      [{pid, _}] when is_pid(pid) and node(pid) == node() ->
        if Process.alive?(pid), do: :healthy, else: :unhealthy
      _ -> :unhealthy
    end
  end

  defp update_domain_status(domains, domain, result) do
    current = domains[domain]
    new_status = if result == :healthy, do: :healthy, else: :unhealthy
    
    Map.put(domains, domain, %{
      status: new_status,
      last_checked: DateTime.utc_now(),
      failure_count: if(result == :healthy, do: 0, else: current.failure_count + 1)
    })
  end

  defp trigger_emergency_isolation(domain) do
    Logger.critical("[HealthCheck] Emergency isolation triggered for domain: #{domain}")
    # Signal root supervisor or restart the domain
    # Implementation depends on the RootSupervisor's interface
    :telemetry.execute(@telemetry_prefix ++ [:emergency_isolation], %{domain: domain})
  end

  defp emit_telemetry(domains) do
    :telemetry.execute(@telemetry_prefix ++ [:status], %{timestamp: DateTime.utc_now()}, domains)
  end
end
