defmodule ProCoder.Memory.Supervisor do
  @moduledoc """
  Supervises the ephemeral context stores (ETS) and persistent stores (Ecto).
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Ecto Repo for persistent storage (moved from individual apps to global)
      {ProCoder.Repo, []}
      
      # ContextStore (ETS Manager) - Managed via Brain subsystem
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
