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

    case launch_cdms(cwd) do
      {:ok, port, project_dir} ->
        Logger.info("[CDMSDaemon] Launching headless CDMS for #{cwd}...")
        {:ok, %{port: port, cwd: cwd, project_dir: project_dir}}

      {:error, reason} ->
        Logger.error("[CDMSDaemon] Could not launch CDMS: #{inspect(reason)}")
        {:ok, %{port: nil, cwd: cwd, project_dir: nil}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_port(port) do
    Logger.debug("[CDMS Output] #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when is_port(port) do
    Logger.warn("[CDMSDaemon] CDMS process exited with status #{status}")
    {:noreply, state}
  end
  
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{port: port}) do
    Logger.info("[CDMSDaemon] Shutting down CDMS process. Reason: #{inspect(reason)}")
    if is_port(port), do: Port.close(port)
  end

  defp launch_cdms(target_dir) do
    with {:ok, project_dir} <- cdms_project_dir(),
         elixir when is_binary(elixir) <- System.find_executable("elixir") do
      suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
      node_id = "agent_node_#{suffix}@127.0.0.1"
      data_dir = Path.join(target_dir, ".cdms_model")

      env = [
        {"ACMS_NODE_NAME", "agent_node"},
        {"ACMS_PORT", "5115"},
        {"CDMS_TARGET_DIR", target_dir},
        {"CDMS_MODE", "generative"},
        {"ACMS_DATA_DIR", data_dir},
        {"REPLACE_OS_VARS", "true"},
        {"MIX_ENV", "dev"}
      ]
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

      port =
        Port.open(
          {:spawn_executable, elixir},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            cd: project_dir,
            args: ["--name", node_id, "--cookie", "secure_cognitive_cookie", "-S", "mix", "run", "--no-halt"],
            env: env
          ]
        )

      {:ok, port, project_dir}
    else
      nil -> {:error, :elixir_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cdms_project_dir do
    case System.get_env("CDMS_HOME") do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ ->
        with executable when is_binary(executable) <- System.find_executable("cdms"),
             {resolved, 0} <- System.cmd("readlink", ["-f", executable]) do
          {:ok, resolved |> String.trim() |> Path.dirname()}
        else
          nil -> {:error, :cdms_command_not_found}
          _ -> {:error, :could_not_resolve_cdms_project}
        end
    end
  end
end
