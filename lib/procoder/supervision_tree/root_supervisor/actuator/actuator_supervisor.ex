defmodule ProCoder.SupervisionTree.RootSupervisor.ActuatorSupervisor do
  @moduledoc """
  The Actuator Supervisor manages the lifecycle of the Actuator domain,
  specifically the CommandRouter (for dispatch) and the PortWrapper (for sandboxed execution).
  """

  use Supervisor
  require Logger

  @doc """
  Starts the Actuator Supervisor under the supervision tree.
  """
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
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

    # Telemetry emission for supervisor initialization
    :telemetry.execute([:procoder, :actuator, :supervisor, :child_start], %{count: length(children)})

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Optional: Health check logic for monitoring child processes.
  If a child is unresponsive, it can be forcefully restarted.
  """
  def handle_info(:health_check, state) do
    # Logic to verify child process responsiveness
    {:noreply, state}
  end
end
