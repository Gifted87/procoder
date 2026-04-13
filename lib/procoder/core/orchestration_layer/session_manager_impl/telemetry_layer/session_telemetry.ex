defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.TelemetryLayer.SessionTelemetry do
  @moduledoc """
  The SessionTelemetry module provides the Telemetry Engine for the ProCoder SessionManager.
  It tracks agent density, churn rates, and resource utilization using atomic ETS counters
  and periodic sampling of agent processes.
  """

  use GenServer
  require Logger

  @table_name :session_telemetry_stats
  @sample_interval 5000 # 5 seconds
  @telemetry_prefix [:procoder]

  # --- API ---

  @doc """
  Starts the SessionTelemetry GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a spawned agent process for monitoring.
  """
  def record_spawn do
    GenServer.cast(__MODULE__, :increment_spawn)
  end

  @doc """
  Registers a terminated agent process for monitoring.
  """
  def record_terminate do
    GenServer.cast(__MODULE__, :increment_terminate)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Stats table: density, started_count, terminated_count
    :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(@table_name, {:density, 0})
    :ets.insert(@table_name, {:started, 0})
    :ets.insert(@table_name, {:terminated, 0})

    schedule_sample()
    {:ok, %{last_started: 0, last_terminated: 0}}
  end

  @impl true
  def handle_cast(:increment_spawn, state) do
    :ets.update_counter(@table_name, :density, 1)
    :ets.update_counter(@table_name, :started, 1)
    
    emit_telemetry([:swarm, :density], %{count: :ets.lookup_element(@table_name, :density, 2)}, %{})
    {:noreply, state}
  end

  @impl true
  def handle_cast(:increment_terminate, state) do
    :ets.update_counter(@table_name, :density, -1)
    :ets.update_counter(@table_name, :terminated, 1)
    
    emit_telemetry([:swarm, :density], %{count: :ets.lookup_element(@table_name, :density, 2)}, %{})
    {:noreply, state}
  end

  @impl true
  def handle_info(:sample, state) do
    sample_resources()
    compute_churn(state)
    
    schedule_sample()
    {:noreply, state}
  end

  # --- Internal Logic ---

  defp sample_resources do
    # Sampling DynamicSupervisor children
    children = Supervisor.which_children(ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager)
    
    Enum.each(children, fn {_, pid, _, _} ->
      try do
        info = :erlang.process_info(pid, [:memory, :reductions])
        if info do
          emit_telemetry([:agent, :metrics], 
            %{mem_bytes: info[:memory], reductions: info[:reductions]}, 
            %{pid: inspect(pid)})
        end
      rescue
        _ -> :ok # Process might have exited
      end
    end)
  end

  defp compute_churn(state) do
    started = :ets.lookup_element(@table_name, :started, 2)
    terminated = :ets.lookup_element(@table_name, :terminated, 2)
    
    started_delta = started - state.last_started
    terminated_delta = terminated - state.last_terminated
    
    emit_telemetry([:swarm, :churn], %{started: started_delta, terminated: terminated_delta}, %{})
    
    {:noreply, %{state | last_started: started, last_terminated: terminated}}
  end

  defp emit_telemetry(event_path, measurements, metadata) do
    try do
      :telemetry.execute(@telemetry_prefix ++ event_path, measurements, sanitize(metadata))
    rescue
      _ -> :ok
    end
  end

  defp sanitize(metadata) do
    # Ensure no PII like full file paths are leaked
    Map.delete(metadata, :path)
  end

  defp schedule_sample do
    Process.send_after(self(), :sample, @sample_interval)
  end
end
