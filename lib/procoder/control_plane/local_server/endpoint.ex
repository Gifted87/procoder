defmodule ProCoder.ControlPlane.LocalServer.Endpoint do
  @moduledoc """
  The LocalServer Endpoint provides a Phoenix-based interface for external tools
  to interact with the ProCoder system via HTTP and WebSockets.
  """

  # In a real implementation, this would use Phoenix.Endpoint
  # For the skeleton, we implement a GenServer that simulates the server lifecycle.

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:procoder, :local_server_port, 4000)
    Logger.info("LocalServer.Endpoint starting on port #{port}")
    {:ok, %{port: port}}
  end

  @impl true
  def handle_call({:request, "GET", "/health", _params}, _from, state) do
    {:reply, {:ok, 200, %{status: :ok, port: state.port}}, state}
  end

  @impl true
  def handle_call({:request, "POST", "/spawn", params}, _from, state) do
    session_id = Map.get(params, "session_id", Ecto.UUID.generate())
    goal = Map.get(params, "goal", "")

    result =
      ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager.spawn_agent(
        session_id,
        goal
      )

    case result do
      {:ok, pid} ->
        {:reply, {:ok, 201, %{session_id: session_id, pid: inspect(pid)}}, state}
      {:error, reason} ->
        {:reply, {:ok, 500, %{error: inspect(reason)}}, state}
    end
  end

  @impl true
  def handle_call({:request, "POST", "/search", params}, _from, state) do
    query = Map.get(params, "query", "")
    session_id = Map.get(params, "session_id", "global")

    result =
      ProCoder.Search.Coordinator.Server.search(query, session_id: session_id, worktree_id: session_id)

    case result do
      {:ok, results} ->
        {:reply, {:ok, 200, %{results: results}}, state}
      {:error, reason} ->
        {:reply, {:ok, 400, %{error: inspect(reason)}}, state}
    end
  end

  @impl true
  def handle_call({:request, _method, path, _params}, _from, state) do
    {:reply, {:ok, 404, %{error: "Not found: #{path}"}}, state}
  end
end
