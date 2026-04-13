defmodule ProCoder.Tooling.PortManager do
  @moduledoc """
  The PortManager is responsible for the lifecycle and pooling of PortWrapper processes.
  It ensures that shell command execution is managed, observable, and cleaned up
  to prevent zombie processes.
  """

  use GenServer
  require Logger

  alias ProCoder.Actuator.PortWrapper

  @type session_id :: String.t()

  # --- API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires a PortWrapper for a specific session.
  """
  def acquire_port(session_id) do
    GenServer.call(__MODULE__, {:acquire, session_id})
  end

  @doc """
  Releases a PortWrapper back to the manager (or terminates it).
  """
  def release_port(session_id, port_pid) do
    GenServer.cast(__MODULE__, {:release, session_id, port_pid})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # registry: %{session_id => port_pid}
    {:ok, %{registry: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, session_id}, _from, state) do
    case Map.get(state.registry, session_id) do
      pid when is_pid(pid) ->
        {:reply, {:ok, pid}, state}

      nil ->
        case PortWrapper.start_link([]) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            new_registry = Map.put(state.registry, session_id, pid)
            new_monitors = Map.put(state.monitors, ref, session_id)
            {:reply, {:ok, pid}, %{state | registry: new_registry, monitors: new_monitors}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:release, _session_id, _pid}, state) do
    # For now, we terminate on release to ensure clean state per command if needed,
    # or we can keep it alive for the session. 
    # Blueprint says "manage lifecycle", let's keep it alive for the session's duration.
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {session_id, new_monitors} when not is_nil(session_id) ->
        new_registry = Map.delete(state.registry, session_id)
        {:noreply, %{state | registry: new_registry, monitors: new_monitors}}

      {nil, _} ->
        {:noreply, state}
    end
  end
end
