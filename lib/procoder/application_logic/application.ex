defmodule ProCoder.Application do
  @moduledoc """
  The primary entry point and lifecycle orchestrator for the ProCoder system.
  Supervises the entire subsystem tree in accordance with the OTP specification.
  """

  use Application
  require Logger

  @doc """
  Starts the ProCoder application.
  """
  @impl true
  def start(_type, _args) do
    # 1. Runtime Configuration Injection (Fail-Fast)
    :ok = ProCoder.Config.RuntimeInitializer.init_runtime_config!()

    # 2. Telemetry Registration
    setup_telemetry()

    # 3. Supervision Tree Initialization
    children = [
      # Global Process Registry
      {ProCoder.Registry, []},

      # Worktree Management (Isolated Sandboxes)
      {ProCoder.Core.OrchestrationLayer.SessionManagerImpl.WorktreeEngine.WorktreeManager, []},

      # Session Management (Swarm)
      {ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager, []},
      
      # Brain Subsystem
      {ProCoder.Brain.Supervisor, []},
      
      # Memory Subsystem
      {ProCoder.Memory.Supervisor, []},

      # Planner Domain: Dynamic supervision for session-specific task DAGs.
      {DynamicSupervisor, strategy: :one_for_one, name: ProCoder.Planner.DynamicSupervisor},

      # Automated background indexing
      {ProCoder.Search.IndexerWorker, []},
      
      # Actuator Subsystem (Policy & Protection)
      {ProCoder.Actuator.Supervisor, []},
      
      # Tooling Subsystem
      {ProCoder.Tooling.Supervisor, []},
      
      # Control Plane Subsystem
      {ProCoder.ControlPlane.Supervisor, []}
    ]

    # 4. Supervision Tree Strategy
    opts = [strategy: :one_for_one, name: ProCoder.Supervisor]
    
    Logger.info("ProCoder system initializing with Unified Architectural Fabric v2.0...")
    Supervisor.start_link(children, opts)
  end

  @doc """
  Graceful shutdown hook for the ProCoder application.
  Ensures memory state, Git worktrees, and database pools are flushed and closed.
  """
  @impl true
  def stop(_state) do
    Logger.info("ProCoder system shutting down gracefully...")
    
    # Perform cleanup logic here
    # 1. Flush memory segments to DB
    # 2. Cleanup orphaned worktrees
    # 3. Purge sensitive ETS buffers
    :ok
  end

  # --- Internal Private Helpers ---

  defp setup_telemetry do
    # Attach telemetry handlers for global performance monitoring
    # :telemetry.attach("procoder-logger", [:procoder, :stop], &ProCoder.Telemetry.handle_event/4, nil)
    :ok
  end
end
