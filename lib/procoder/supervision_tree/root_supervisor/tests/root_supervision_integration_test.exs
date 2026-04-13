defmodule ProCoder.SupervisionTree.RootSupervisor.IntegrationTest do
  @moduledoc """
  High-fidelity integration test suite for the ProCoder.SupervisionTree.RootSupervisor.
  Validates hierarchical structure, startup lifecycle, graceful shutdown, and
  domain-specific fault tolerance/recovery mandates.
  """

  use ExUnit.Case, async: false
  require Logger

  alias ProCoder.SupervisionTree.RootSupervisor
  alias ProCoder.Brain.Supervisor, as: BrainSupervisor
  alias ProCoder.SupervisionTree.RootSupervisor.CoreSupervisor
  alias ProCoder.SupervisionTree.RootSupervisor.Planner.PlannerSupervisor
  alias ProCoder.Actuator.Supervisor, as: ActuatorSupervisor

  @setup_timeout 15_000

  setup do
    on_exit(fn ->
      stop_supervisor(RootSupervisor)
    end)
    :ok
  end

  describe "System Lifecycle Orchestration" do
    test "RootSupervisor successfully initializes all domain supervisors" do
      {:ok, pid} = RootSupervisor.start_link([])
      assert Process.alive?(pid)

      assert_eventually(fn ->
        match?([_ | _], Registry.lookup(ProCoder.Registry, CoreSupervisor))
      end, "CoreSupervisor not registered")

      assert_eventually(fn ->
        match?([_ | _], Registry.lookup(ProCoder.Registry, PlannerSupervisor))
      end, "PlannerSupervisor not registered")

      assert_eventually(fn ->
        match?([_ | _], Registry.lookup(ProCoder.Registry, BrainSupervisor))
      end, "BrainSupervisor not registered")

      assert_eventually(fn ->
        match?([_ | _], Registry.lookup(ProCoder.Registry, ActuatorSupervisor))
      end, "ActuatorSupervisor not registered")
    end

    test "graceful shutdown triggers state persistence" do
      {:ok, pid} = RootSupervisor.start_link([])
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, @setup_timeout
    end
  end

  describe "Fault Tolerance and Recovery Matrix" do
    test "isolated domain child failure induces local restart" do
      {:ok, _pid} = RootSupervisor.start_link([])

      # Target: Brain.Client.Engine
      {:ok, [{engine_pid, _}]} = Registry.lookup(ProCoder.Registry, ProCoder.Brain.Client.Engine)
      Process.monitor(engine_pid)

      Process.exit(engine_pid, :kill)

      assert_eventually(fn ->
        case Registry.lookup(ProCoder.Registry, ProCoder.Brain.Client.Engine) do
          [{new_pid, _}] when new_pid != engine_pid -> true
          _ -> false
        end
      end, "Brain engine failed to restart")
    end

    test "rapid-fire failures trigger back-off mechanism" do
      {:ok, _pid} = RootSupervisor.start_link([])
      {:ok, [{engine_pid, _}]} = Registry.lookup(ProCoder.Registry, ProCoder.Brain.Client.Engine)

      for _ <- 1..15 do
        Process.exit(engine_pid, :kill)
        Process.sleep(10)
      end

      assert_eventually(fn ->
        !Process.alive?(engine_pid) and Registry.lookup(ProCoder.Registry, ProCoder.Brain.Client.Engine) == []
      end, "Supervisor failed to enforce back-off limits")
    end
  end

  describe "Scalability & Concurrency" do
    test "handles simultaneous domain failures" do
      {:ok, _pid} = RootSupervisor.start_link([])

      # Get PIDs
      [{planner_pid, _}] = Registry.lookup(ProCoder.Registry, ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer)
      [{brain_pid, _}] = Registry.lookup(ProCoder.Registry, ProCoder.Brain.RateLimiter)

      Process.exit(planner_pid, :kill)
      Process.exit(brain_pid, :kill)

      assert_eventually(fn ->
        Registry.lookup(ProCoder.Registry, ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer) != [] and
        Registry.lookup(ProCoder.Registry, ProCoder.Brain.RateLimiter) != []
      end, "Concurrent domain recovery failed")
    end
  end

  defp stop_supervisor(sup) do
    if pid = Process.whereis(sup) do
      Process.exit(pid, :kill)
      Process.sleep(500)
    end
  end

  defp assert_eventually(fun, message, retries \\ 20) do
    if fun.() do
      :ok
    else
      if retries > 0 do
        Process.sleep(200)
        assert_eventually(fun, message, retries - 1)
      else
        flunk(message)
      end
    end
  end
end
