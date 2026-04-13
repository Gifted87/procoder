defmodule ProCoder.Actuator.Supervisor do
  @moduledoc """
  Supervises the Actuator subsystem, including the PolicyEngine and execution layers.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Security & Audit Pillar
      {ProCoder.Actuator.PolicyLogic.PolicyEngine, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
