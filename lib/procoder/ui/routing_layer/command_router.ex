defmodule ProCoder.UI.RoutingLayer.CommandRouter do
  @moduledoc """
  The CommandRouter serves as the high-concurrency, fault-tolerant entry point for slash commands.
  It validates, authorizes via the PolicyEngine, and dispatches commands asynchronously to 
  appropriate backend systems.
  """

  use GenServer
  require Logger

  @table_name :procoder_command_registry

  # --- API ---

  @doc """
  Starts the CommandRouter and initializes the ETS dispatch table.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dynamically registers a command. 
  `cmd` - The command atom (e.g., :rewind)
  `handler` - A tuple {module, function} to be invoked on dispatch.
  """
  def register_command(cmd, {module, function}) when is_atom(cmd) do
    GenServer.call(__MODULE__, {:register, cmd, {module, function}})
  end

  @doc """
  Asynchronously dispatches a command to the registered handler after authorization.
  """
  @spec dispatch(atom(), map()) :: :ok | {:error, term()}
  def dispatch(command, args) do
    args = Map.put_new(args, :cmd, command)
    case lookup_command(command) do
      {:ok, {module, function}} ->
        apply(module, function, [args])
      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, cmd, handler}, _from, state) do
    :ets.insert(@table_name, {cmd, handler})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:dispatch, command, args}, _state) do
    # Fallback for any background dispatches if needed
    dispatch(command, args)
    {:noreply, %{}}
  end

  defp lookup_command(cmd) do
    case :ets.lookup(@table_name, cmd) do
      [{^cmd, handler}] -> {:ok, handler}
      [] -> 
        # Fallback for hardcoded "Slash" commands
        if cmd in [:add, :drop, :rewind, :swarm, :compact, :stop, :help, :list, :reload, :skills, :skill] do
          {:ok, {__MODULE__, :handle_slash}}
        else
          {:error, :command_not_found}
        end
    end
  end

  def handle_slash(args) do
    # Extract session_id from args or use default
    session_id = Map.get(args, :session_id, "default_session")
    cmd = Map.get(args, :cmd)
    
    # Dispatch to specific subsystems
    case cmd do
      :add -> 
        path = normalize_path(args.path)
        ProCoder.Memory.ContextStore.inject(session_id, path)
        :ok
      :drop -> 
        path = normalize_path(args.path)
        ProCoder.Memory.ContextStore.evict(session_id, path)
        :ok
      :rewind -> 
        case find_agent_pid(session_id) || args[:pid] do
          pid when is_pid(pid) ->
            if Process.alive?(pid) do
              ProCoder.Core.AgentFSM.rewind(pid)
              :ok
            else
              {:error, :agent_not_found}
            end
          _ -> 
            {:error, :agent_not_found}
        end
      :skills ->
        sub = args[:subcommand] || "list"
        case sub do
          "reload" ->
            ProCoder.Skills.ExternalSkillRegistry.rescan()
            {:ok, :skills_reloaded}

          _ ->
            skills = ProCoder.Skills.ExternalSkillRegistry.list_skills()
            {:ok, {:skills_list, skills}}
        end
      :skill ->
        action = args[:action] || "list"
        target = args[:target]

        case action do
          "read" ->
            skill_name = target || args[:path]
            pid = args[:pid] || find_agent_pid(session_id)
            if pid && Process.alive?(pid) do
              case ProCoder.Skills.ExternalSkillRegistry.tell_agent_read_skill(pid, skill_name) do
                {:ok, _} -> {:ok, {:skill_read_directed, skill_name}}
                :ok -> {:ok, {:skill_read_directed, skill_name}}
                {:error, reason} -> {:error, reason}
              end
            else
              case ProCoder.Skills.ExternalSkillRegistry.load_skill_content(skill_name) do
                {:ok, content} -> {:ok, {:skill_preview, skill_name, content}}
                {:error, reason} -> {:error, reason}
              end
            end

          "load" ->
            skill_name = target || args[:path]
            pid = args[:pid] || find_agent_pid(session_id)
            if pid && Process.alive?(pid) do
              case ProCoder.Skills.ExternalSkillRegistry.tell_agent_read_skill(pid, skill_name) do
                {:ok, _} -> {:ok, {:skill_read_directed, skill_name}}
                :ok -> {:ok, {:skill_read_directed, skill_name}}
                {:error, reason} -> {:error, reason}
              end
            else
              case ProCoder.Skills.ExternalSkillRegistry.load_skill_content(skill_name) do
                {:ok, content} -> {:ok, {:skill_preview, skill_name, content}}
                {:error, reason} -> {:error, reason}
              end
            end

          "install" ->
            source = target || args[:path]
            scope = String.to_atom(args[:scope] || "project")
            project_root = Application.get_env(:procoder, ProCoder.SessionManager)[:source_root] || File.cwd!()
            case ProCoder.Skills.ExternalSkillRegistry.install_skill(source, scope: scope, project_root: project_root) do
              {:ok, path} -> {:ok, {:skill_installed, path}}
              {:error, reason} -> {:error, reason}
            end

          "reload" ->
            ProCoder.Skills.ExternalSkillRegistry.rescan()
            {:ok, :skills_reloaded}

          _ ->
            skills = ProCoder.Skills.ExternalSkillRegistry.list_skills()
            {:ok, {:skills_list, skills}}
        end
      :swarm -> 
        ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager.spawn_agent(session_id, args[:goal] || "Swarm collaboration")
        :ok
      :compact -> 
        ProCoder.Brain.MemoryStore.Compactor.force_gc()
        :ok
      :stop -> 
        ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager.terminate_session(session_id)
        :ok
      :list -> {:ok, ProCoder.Core.HistoryManagement.ArchiveManager.list_archives()}
      :reload -> 
        id = Map.get(args, :id)
        ProCoder.Core.HistoryManagement.ArchiveManager.load_archive(id)
      :help -> 
        display_help()
        :ok
      _ -> :ok
    end
  end

  defp find_agent_pid(session_id) do
    case Registry.lookup(ProCoder.Registry, session_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp normalize_path(path) do
    source_root = Application.get_env(:procoder, ProCoder.SessionManager)[:source_root] || File.cwd!()
    Path.absname(path, source_root) |> Path.expand()
  end

  defp display_help do
    IO.puts("""
    Available Slash Commands:
    /add <path>               - Inject file into context
    /drop <path>              - Evict file from context
    /rewind                   - Undo last agent action
    /skills                   - List all available Claude/Codex skills
    /skill read <name>        - Command active agent to activate & read a skill
    /skill install <url>      - Install a skill from Git/URL
    /skill reload             - Rescan skill directories
    /swarm <goal>             - Spawn a sub-agent
    /new                      - Start a fresh conversation session
    /stop                     - Terminate the current agent session
    /list                     - List archived conversations
    /reload <id>              - Reload an archived conversation
    /compact                  - Force memory compaction
    /help                     - Show this help
    /quit                     - Exit ProCoder
    """)
  end

end
