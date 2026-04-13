defmodule ProCoder.ControlPlane.Supervisor do
  @moduledoc """
  Supervises the CommandRouter and TUI interface.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Command dispatch and slash-command routing
      {ProCoder.UI.RoutingLayer.CommandRouter, []},
      
      # TUI rendering process
      {ProCoder.UI.ViewLayer.TuiView, []},

      # External API Gateway
      {ProCoder.ControlPlane.LocalServer.Endpoint, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
