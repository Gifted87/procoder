defmodule ProCoder.Tooling.CDMSDaemon do
  @moduledoc """
  A GenServer that ensures the external CDMS process is started
  and gracefully shut down when ProCoder terminates.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # Determine target directory
    cwd = System.get_env("PROCODER_SOURCE_ROOT") || System.get_env("PWD") || File.cwd!()
    
    # Launch CDMS
    Logger.info("[CDMSDaemon] Launching CDMS in #{cwd}...")
    
    # Open as a Port so it is linked to this process and dies when we do
    port = Port.open(
      {:spawn_executable, System.find_executable("sh")},
      [
        :binary,
        cd: cwd,
        args: ["-c", "cdms --port 5115 --mode generative --name agent_node"]
      ]
    )

    {:ok, %{port: port, cwd: cwd}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("[CDMS Output] #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warn("[CDMSDaemon] CDMS process exited with status #{status}")
    {:noreply, state}
  end
  
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{port: port}) do
    Logger.info("[CDMSDaemon] Shutting down CDMS process. Reason: #{inspect(reason)}")
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end
end
