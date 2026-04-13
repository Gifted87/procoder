defmodule ProCoder.Registry do
  @moduledoc """
  Global registry for ProCoder processes, including sessions and agents.
  """
  
  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  # Helper for looking up pids, although Registry.lookup is standard
  def lookup(key) do
    Registry.lookup(__MODULE__, key)
  end
end
