defmodule ProCoder.UI.ViewLayer.TuiView do
  @moduledoc """
  The primary interactive interface for ProCoder.
  Provides a terminal chat loop with agent progress and command feedback.
  """

  # Ensure the module is properly named according to the supervision tree
  # RootSupervisor.ControlPlane.Supervisor calls ProCoder.UI.ViewLayer.TuiView

  use GenServer
  require Logger

  alias ProCoder.UI.RoutingLayer.CommandRouter
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager

  @prompt "› "

  # --- API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # Generate a stable unique session ID for this TUI instance
    session_id = "session_#{Ecto.UUID.generate()}"
    
    # Start the REPL loop in a separate task so we don't block the GenServer
    # We pass self() so the REPL can send messages back to the GenServer if needed
    parent = self()
    Task.start_link(fn ->
      Process.sleep(500)
      repl_loop(parent)
    end)

    {:ok, %{session_id: session_id, active_agent_pid: nil, pending_goal: nil}}
  end

  @impl true
  def handle_call({:get_active_agent}, _from, state) do
    {:reply, state.active_agent_pid, state}
  end

  def handle_call({:submit_goal, goal}, _from, state) do
    cond do
      state.pending_goal != nil ->
        {:reply, :busy, state}

      is_pid(state.active_agent_pid) and Process.alive?(state.active_agent_pid) ->
        GenServer.cast(state.active_agent_pid, {:plan, goal})
        {:reply, :continued, state}

      true ->
        parent = self()
        session_id = state.session_id

        case Task.start(fn ->
               result =
                 try do
                   SessionManager.spawn_agent(session_id, goal, force_fresh: false, ui_pid: parent)
                 rescue
                   error -> {:error, Exception.message(error)}
                 catch
                   :exit, reason -> {:error, reason}
                 end

               send(parent, {:agent_spawned, session_id, goal, result})
             end) do
          {:ok, _task_pid} -> {:reply, :starting, %{state | pending_goal: goal}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:set_active_agent, pid}, state) do
    {:noreply, %{state | active_agent_pid: pid}}
  end

  def handle_cast({:set_session, session_id}, state) do
    {:noreply, %{state | session_id: session_id}}
  end

  @impl true
  def handle_info({:agent_spawned, session_id, goal, {:ok, pid}}, state)
      when session_id == state.session_id and goal == state.pending_goal do
    Owl.IO.puts([
      Owl.Data.tag("\n● Agent ready", :green),
      "  ",
      Owl.Data.tag("Working on your request…", :cyan),
      "\n"
    ])

    {:noreply, %{state | active_agent_pid: pid, pending_goal: nil}}
  end

  def handle_info({:agent_spawned, session_id, goal, {:error, reason}}, state)
      when session_id == state.session_id and goal == state.pending_goal do
    Owl.IO.puts(Owl.Data.tag("\nCould not start agent: #{inspect(reason)}\n", :red))
    {:noreply, %{state | pending_goal: nil}}
  end

  def handle_info({:agent_event, session_id, :thinking}, %{session_id: session_id} = state) do
    Owl.IO.puts(Owl.Data.tag("\n◌ Thinking…", :cyan))
    {:noreply, state}
  end

  def handle_info({:agent_event, session_id, {:tools, names}}, %{session_id: session_id} = state) do
    Owl.IO.puts(Owl.Data.tag("\n↳ Using #{Enum.join(names, ", ")}", :yellow))
    {:noreply, state}
  end

  def handle_info({:agent_event, session_id, {:tools_done, names}}, %{session_id: session_id} = state) do
    Owl.IO.puts(Owl.Data.tag("✓ Finished #{Enum.join(names, ", ")}", :green))
    {:noreply, state}
  end

  def handle_info({:agent_event, session_id, {:llm_error, reason}}, %{session_id: session_id} = state) do
    Owl.IO.puts(Owl.Data.tag("\nModel request failed: #{inspect(reason)}", :red))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Internal REPL Loop ---

  defp repl_loop(parent) do
    # Enable bracketed paste mode: \e[?2004h
    IO.write("\e[?2004h")

    Owl.IO.puts([
      Owl.Data.tag("\n╭─ ProCoder", :bright),
      "  ",
      Owl.Data.tag("qwen3.8-27b", :cyan),
      "\n│ Describe a task, or use /help for commands.\n╰────────────────────────────────────────\n"
    ])

    loop(parent)
  end

  defp loop(parent) do
    input =
      case IO.gets(@prompt) do
        :eof -> :eof
        nil -> :eof
        line -> line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
      end

    input = case input do
      "\e[200~" <> _ = start -> collect_bracketed_paste(start)
      other -> other
    end

    case input do
      :eof ->
        Logger.info("[TUI] Standard input closed; interactive prompt stopped.")

      nil -> 
        loop(parent)

      "/new" ->
        # Archive and Terminate the current session if one exists
        old_session_id = :sys.get_state(parent).session_id
        ProCoder.Core.HistoryManagement.ArchiveManager.archive_current_session(old_session_id)
        SessionManager.terminate_session(old_session_id)
        
        session_id = "session_#{Ecto.UUID.generate()}"
        GenServer.cast(parent, {:set_session, session_id})
        GenServer.cast(parent, {:set_active_agent, nil})
        Owl.IO.puts(Owl.Data.tag("\nNew session started: #{session_id}", :bright))
        loop(parent)

      "/quit" ->
        IO.write("\e[?2004l")
        System.stop()

      "/exit" ->
        IO.write("\e[?2004l")
        System.stop()

      "/" <> command_string ->
        handle_slash_command(command_string, parent)
        loop(parent)

      "" -> 
        loop(parent)

      goal ->
        handle_natural_language_goal(goal, parent)
        loop(parent)
    end
  end

  defp handle_slash_command(command_string, parent) do
    parts = String.split(command_string)
    case parts do
      [cmd_name | args] ->
        cmd_atom = String.to_atom(cmd_name)
        active_agent_pid = GenServer.call(parent, {:get_active_agent})
        
        # Improved args parsing for specific commands
        dispatch_args = case {cmd_atom, args} do
          {:reload, [id]} -> %{id: id}
          {:skills, [sub | _]} -> %{subcommand: sub}
          {:skills, []} -> %{subcommand: "list"}
          {:skill, [action, target | rest]} ->
            scope = List.first(rest) || "project"
            %{action: action, target: target, scope: scope, path: target}
          {:skill, [action]} ->
            %{action: action}
          {:skill, []} ->
            %{action: "list"}
          {_, [path | rest]} -> %{path: path, goal: Enum.join(rest, " ")}
          {_, []} -> %{}
        end
        
        # Add cmd atom and context to args
        dispatch_args = dispatch_args
          |> Map.put(:cmd, cmd_atom)
          |> Map.put(:session_id, :sys.get_state(parent).session_id)
          |> Map.put(:pid, active_agent_pid)

        case CommandRouter.dispatch(cmd_atom, dispatch_args) do
          :ok -> 
            if cmd_atom == :rewind do
              Owl.IO.puts(Owl.Data.tag("\nRewind request sent to agent.", :cyan))
            end
            :ok
          
          # Handle /list result
          {:ok, archives} when is_list(archives) ->
            Owl.IO.puts("\n" <> Owl.Data.tag("Archived Conversations:", :bright))
            if archives == [] do
              Owl.IO.puts("  (No archives found)")
            else
              archives
              |> Enum.each(fn arc ->
                Owl.IO.puts("  - [#{Owl.Data.tag(arc.id, :cyan)}] #{arc.timestamp}: #{arc.title}")
              end)
              Owl.IO.puts("\nUse " <> Owl.Data.tag("/reload <id>", :cyan) <> " to restore a conversation.\n")
            end

          # Handle /skills list result
          {:ok, {:skills_list, skills}} ->
            Owl.IO.puts("\n" <> Owl.Data.tag("=== DISCOVERED CLAUDE / CODEX SKILLS ===", :bright))
            if skills == [] do
              Owl.IO.puts("  (No skills found in ~/.gemini/config/skills, ~/.claude/skills, or .claude/skills)")
            else
              Enum.each(skills, fn skill ->
                scope_tag = if skill.scope == :project, do: Owl.Data.tag("[project]", :green), else: Owl.Data.tag("[global]", :cyan)
                Owl.IO.puts("  #{scope_tag} #{Owl.Data.tag(skill.name, :bright)} - #{skill.description}")
                if skill.allowed_tools != [], do: Owl.IO.puts("      Tools: #{Enum.join(skill.allowed_tools, ", ")}")
              end)
            end
            Owl.IO.puts("\nCommands: " <> Owl.Data.tag("/skill read <name>", :yellow) <> " | " <> Owl.Data.tag("/skill install <url>", :yellow) <> " | " <> Owl.Data.tag("/skill reload", :yellow) <> "\n")

          # Handle /skill read / tell agent
          {:ok, {:skill_read_directed, skill_name}} ->
            Owl.IO.puts(Owl.Data.tag("✓ Directed active agent to activate and read skill '#{skill_name}'.", :green))

          # Handle /skill preview when no agent running
          {:ok, {:skill_preview, skill_name, content}} ->
            Owl.IO.puts("\n" <> Owl.Data.tag("=== SKILL: #{skill_name} ===", :cyan))
            Owl.IO.puts(content)
            Owl.IO.puts(Owl.Data.tag("(No active agent session running to inject into)", :yellow))

          # Handle /skill install
          {:ok, {:skill_installed, path}} ->
            Owl.IO.puts(Owl.Data.tag("✓ Successfully installed skill to: #{path}", :green))

          # Handle /skill reload
          {:ok, :skills_reloaded} ->
            Owl.IO.puts(Owl.Data.tag("✓ Skills re-scanned and registry updated.", :green))

          # Handle /reload result
          {:ok, %{"id" => id, "history" => history, "title" => title}} ->
            Owl.IO.puts(Owl.Data.tag("\nReloading session: #{title} (#{id})", :bright))
            
            # 1. Terminate current session
            current_session_id = :sys.get_state(parent).session_id
            SessionManager.terminate_session(current_session_id)
            
            # 2. Update TUI state
            GenServer.cast(parent, {:set_session, id})
            
            # 3. Spawn a new agent with the reloaded history
            case SessionManager.spawn_agent(id, title, history: history) do
              {:ok, pid} -> 
                GenServer.cast(parent, {:set_active_agent, pid})
                Owl.IO.puts(Owl.Data.tag("Session reloaded and active.", :green))
              _ -> 
                Owl.IO.puts(Owl.Data.tag("Failed to restart agent after reload.", :red))
            end

          {:error, :agent_not_found} ->
            Owl.IO.puts(Owl.Data.tag("No active agent found for this session.", :red))

          {:error, reason} ->
            Owl.IO.puts(Owl.Data.tag("Command failed: #{inspect(reason)}", :red))
        end
      _ -> :ok
    end
  end

  defp handle_natural_language_goal(goal, parent) do
    case GenServer.call(parent, {:submit_goal, goal}) do
      :starting ->
        Owl.IO.puts(Owl.Data.tag("\n◌ Preparing your workspace…\n", :cyan))

      :continued ->
        Owl.IO.puts(Owl.Data.tag("\n↳ Added to the current session.\n", :cyan))

      :busy ->
        Owl.IO.puts(Owl.Data.tag("\nThe current workspace is still being prepared. Please wait.\n", :yellow))

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("\nCould not start provisioning: #{inspect(reason)}\n", :red))
    end
  end

  defp collect_bracketed_paste(acc) do
    if String.contains?(acc, "\e[201~") do
      acc 
      |> String.replace("\e[200~", "") 
      |> String.replace("\e[201~", "") 
      |> String.trim()
    else
      case IO.gets("") do
        :eof -> 
          acc 
          |> String.replace("\e[200~", "") 
          |> String.trim()
        next -> 
          collect_bracketed_paste(acc <> "\n" <> next)
      end
    end
  end
end
