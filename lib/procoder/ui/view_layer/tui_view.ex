defmodule ProCoder.UI.ViewLayer.TuiView do
  @moduledoc """
  The primary interactive interface for ProCoder.
  Provides a Claude Code-like REPL loop using the Owl library.
  """

  # Ensure the module is properly named according to the supervision tree
  # RootSupervisor.ControlPlane.Supervisor calls ProCoder.UI.ViewLayer.TuiView

  use GenServer
  require Logger

  alias ProCoder.UI.RoutingLayer.CommandRouter
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager

  @prompt "> "

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
    Task.start(fn -> 
      Process.sleep(500)
      repl_loop(parent) 
    end)
    
    {:ok, %{session_id: session_id, active_agent_pid: nil}}
  end

  @impl true
  def handle_call({:get_active_agent}, _from, state) do
    {:reply, state.active_agent_pid, state}
  end

  @impl true
  def handle_cast({:set_active_agent, pid}, state) do
    {:noreply, %{state | active_agent_pid: pid}}
  end

  @impl true
  def handle_cast({:set_session, session_id}, state) do
    {:noreply, %{state | session_id: session_id}}
  end

  # --- Internal REPL Loop ---

  defp repl_loop(parent) do
    # Enable bracketed paste mode: \e[?2004h
    IO.write("\e[?2004h")

    Owl.IO.puts([
      Owl.Data.tag("\nProCoder v2.0", :bright),
      " - The Elixir/OTP Agentic Harness\n",
      "Type ", Owl.Data.tag("/help", :cyan), " for commands, or just state your goal.\n"
    ])

    loop(parent)
  end

  defp loop(parent) do
    input = try do
      Owl.IO.input(label: @prompt, optional: true)
    rescue
      _ -> nil
    end

    input = case input do
      "\e[200~" <> _ = start -> collect_bracketed_paste(start)
      other -> other
    end

    case input do
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
    active_agent_pid = GenServer.call(parent, {:get_active_agent})
    state = :sys.get_state(parent) # Get session_id from state
    session_id = state.session_id

    if active_agent_pid && Process.alive?(active_agent_pid) do
      # Reuse the existing agent for multi-turn
      GenServer.cast(active_agent_pid, {:plan, goal})
      Owl.IO.puts(Owl.Data.tag("Continuing session #{session_id} with agent #{inspect(active_agent_pid)}", :cyan))
    else
      # Spawn a new agent for the session. We set force_fresh: false here 
      # so that if an agent crashes and restarts, it RESTORES its history.
      # Users can still use /new to start a truly fresh session.
      case SessionManager.spawn_agent(session_id, goal, force_fresh: false) do
        {:ok, pid} ->
          GenServer.cast(parent, {:set_active_agent, pid})
          Owl.IO.puts(Owl.Data.tag("Agent spawned (PID: #{inspect(pid)}) for goal: #{goal}", :green))
        {:error, reason} ->
          Owl.IO.puts(Owl.Data.tag("Failed to spawn agent: #{inspect(reason)}", :red))
      end
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
