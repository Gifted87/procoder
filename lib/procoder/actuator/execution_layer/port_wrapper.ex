defmodule ProCoder.Actuator.PortWrapper do
  @moduledoc """
  A robust, sandboxed wrapper around Erlang Ports for executing shell commands.
  Provides security, observability, and resource isolation using Bubblewrap (Linux)
  or Seatbelt (macOS).
  """

  use GenServer
  require Logger

  @type status :: :idle | :running | :completed | :failed | :timed_out

  @doc """
  Starts a new PortWrapper process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Executes a command asynchronously.
  `cmd` - The binary command path (e.g., "/usr/bin/git")
  `args` - List of arguments.
  `worktree` - The working directory to sandbox the execution.
  """
  def execute(pid, cmd, args, worktree, timeout \\ 5000) do
    GenServer.call(pid, {:execute, cmd, args, worktree, timeout})
  end

  @impl true
  def init(_opts) do
    {:ok, %{port: nil, caller: nil, stdout: "", status: :idle, timer: nil}}
  end

  @impl true
  def handle_call({:execute, cmd, args, worktree, timeout}, {from_pid, _ref}, state) do
    # Validate command path against whitelist
    case validate_command!(cmd) do
      :ok ->
        {sandboxed_cmd, sandboxed_args} = build_sandbox_command(cmd, args, worktree)
        
        port = Port.open({:spawn_executable, sandboxed_cmd}, [
          :exit_status,
          :stderr_to_stdout,
          :binary,
          :use_stdio,
          args: sandboxed_args,
          cd: worktree,
          env: [{"PATH", "/usr/bin:/bin"}] # Scrubbed environment
        ])

        timer = Process.send_after(self(), :timeout, timeout)
        
        {:reply, :ok, %{state | port: port, caller: from_pid, status: :running, timer: timer}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, caller: caller} = state) do
    send(caller, {:stdout, data})
    {:noreply, %{state | stdout: state.stdout <> data}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, caller: caller, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    send(caller, {:exit_status, status})
    {:noreply, %{state | port: nil, status: :completed, timer: nil}}
  end

  @impl true
  def handle_info(:timeout, %{port: port, caller: caller} = state) do
    if port do
      Port.close(port)
      Process.exit(port, :kill)
    end
    send(caller, {:error, :timeout})
    {:noreply, %{state | port: nil, status: :timed_out}}
  end

  # Explicit allowlist of safe executables the agent may invoke
  @allowed_commands MapSet.new([
    "/usr/bin/git",
    "/usr/bin/mix",
    "/usr/bin/elixir",
    "/usr/bin/iex",
    "/usr/bin/rg",
    "/usr/bin/fd",
    "/usr/bin/diff",
    "/bin/cat",
    "/bin/ls",
    "/bin/echo",
    "/bin/sh",
    "/usr/bin/env",
    "/usr/bin/python3",
    "/usr/bin/node",
    "/usr/bin/npm",
    "/usr/bin/bwrap"
  ])

  defp validate_command!(cmd) do
    if MapSet.member?(@allowed_commands, cmd) do
      :ok
    else
      Logger.warning("[PortWrapper] Blocked unauthorized command: #{cmd}")
      {:error, :unauthorized_command}
    end
  end

  # Helper: Sandbox construction
  # Uses Bubblewrap (bwrap) on Linux.
  defp build_sandbox_command(cmd, args, worktree) do
    # Note: Simplified for the implementation skeleton.
    # In practice, this would involve complex flags for read-only root, 
    # bind-mounting the specific worktree, and resource limiting.
    sandbox_cmd = "/usr/bin/bwrap"
    sandbox_args = [
      "--ro-bind", "/usr", "/usr",
      "--ro-bind", "/lib", "/lib",
      "--ro-bind", "/lib64", "/lib64",
      "--bind", worktree, worktree,
      "--chdir", worktree,
      cmd | args
    ]
    
    {sandbox_cmd, sandbox_args}
  end
end
