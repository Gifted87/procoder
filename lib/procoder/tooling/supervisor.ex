defmodule ProCoder.Tooling.Supervisor do
  @moduledoc """
  Supervises OS ports, LSP servers, and search coordinators.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Search Coordination Engine Components
      {ProCoder.Search.CoordinatorLogicEngine.FsmCoreLogicEngine, []},
      {ProCoder.Search.Coordinator.Server, []},

      # Port Management
      {ProCoder.Tooling.PortManager, []},

      # LSP Subsystem
      {ProCoder.Tooling.LSP.Supervisor, []},
      {ProCoder.Tooling.LSP.Manager, []},

      # CDMS Node process
      {ProCoder.Tooling.CDMSDaemon, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
