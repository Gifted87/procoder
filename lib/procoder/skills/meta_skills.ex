defmodule ProCoder.Skills.AgentForgeSkill do
  @moduledoc """
  Skill for dynamic agent creation and runtime compilation.
  Enables the agent to build new specialists using ProCoder's Macro DSL.
  """
  require Logger
  alias ProCoder.Core.AgentLogic.ToolDefinitions

  @doc """
  Generates and compiles a new agent module at runtime.
  """
  def create_specialist(args) do
    raw_name = args["name"] || "Specialist_#{:erlang.unique_integer([:positive])}"
    clean_name = Macro.camelize(to_string(raw_name))
    goal_type = args["goal_type"] || "specialized engineering tasks"
    custom_code = args["dsl_code"]

    code =
      cond do
        custom_code && String.trim(custom_code) != "" ->
          cond do
            String.contains?(custom_code, "defmodule") ->
              custom_code

            String.contains?(custom_code, "defagent") ->
              """
              use ProCoder.SDK.MacroDSL.Agents.AgentMacro

              #{custom_code}
              """

            true ->
              """
              use ProCoder.SDK.MacroDSL.Agents.AgentMacro

              defagent #{clean_name} do
                persona \"\"\"
                You are a specialized ProCoder agent focused on #{goal_type}.
                \"\"\"

                #{custom_code}
              end
              """
          end

        true ->
          tools = Map.get(args, "tools", ["read_file", "write_file"])
          """
          use ProCoder.SDK.MacroDSL.Agents.AgentMacro

          defagent #{clean_name} do
            persona \"\"\"
            You are a specialized ProCoder agent focused on #{goal_type}.
            You have access to standard tools: #{Enum.join(tools, ", ")}.
            \"\"\"
          end
          """
      end

    file_path = "/tmp/#{clean_name}_agent.ex"
    File.write!(file_path, code)

    try do
      compiled_modules = Code.compile_file(file_path)
      target_mod = 
        case compiled_modules do
          [{mod, _} | _] -> mod
          _ -> Module.concat([ProCoder.Agents.Specialist, clean_name])
        end

      # Register custom skills with ToolDefinitions
      ToolDefinitions.register_module_skills(target_mod)

      # Register specialist in Registry
      try do
        Registry.register(ProCoder.Registry, "specialist_#{clean_name}", target_mod)
      rescue
        _ -> :ok
      end

      skills = if Code.ensure_loaded?(target_mod) and function_exported?(target_mod, :__skills__, 0), do: target_mod.__skills__(), else: []

      Logger.info("Forge: Compiled and registered new agent module: #{inspect(target_mod)}")
      {:ok, "Specialist agent '#{clean_name}' has been forged and compiled. Module: #{inspect(target_mod)}. Exported skills: #{inspect(skills)}. Ready to run in ReAct loop."}
    rescue
      e ->
        Logger.error("Forge failed: #{inspect(e)}")
        {:error, "Forge failed: #{inspect(e)}"}
    end
  end

  @doc """
  Reads the entire Macro DSL codebase to provide context for agent synthesis.
  """
  def fetch_dsl_spec do
    sdk_root = "/home/gifted/procoder_system/lib/procoder/sdk/dsl_engine/macro_dsl"
    
    files = [
      Path.join(sdk_root, "agents/agent_macro.ex"),
      Path.join(sdk_root, "skills/skill_macro.ex"),
      Path.join(sdk_root, "requirements/requirements.ex")
    ]

    contents = Enum.map(files, fn path ->
      case File.read(path) do
        {:ok, content} -> "### FILE: #{Path.relative_to(path, "/home/gifted/procoder_system")}\n#{content}\n"
        _ -> ""
      end
    end) |> Enum.join("\n---\n")

    {:ok, "Macro DSL Specification:\n#{contents}"}
  end
end

defmodule ProCoder.Skills.SwarmOrchestrationSkill do
  @moduledoc """
  Skill for parallel execution and sub-agent management.
  Allows a commander agent to commission specialized swarms.
  """
  require Logger
  alias ProCoder.Core.OrchestrationLayer.SessionManagerImpl.SupervisorCore.SessionManager

  @doc """
  Spawns a specialized sub-agent to handle a delegated goal.
  """
  def spawn_worker(args) do
    session_id = args["session_id"] || "worker"
    sub_session_id = "#{session_id}_worker_#{:erlang.unique_integer([:positive])}"
    goal = args["goal"] || "Execute assigned sub-task"

    mod_param = args["module"]
    module = resolve_agent_module(mod_param)

    opts = [
      module: module,
      specialist_module: (if module != ProCoder.Core.AgentFSM, do: module, else: nil)
    ]

    case SessionManager.spawn_agent(sub_session_id, goal, opts) do
      {:ok, pid} ->
        {:ok, "Worker spawned successfully [ID: #{sub_session_id}, PID: #{inspect(pid)}, Module: #{inspect(module)}]. ReAct FSM loop active."}
      {:error, reason} ->
        {:error, "Failed to spawn worker: #{inspect(reason)}"}
    end
  end

  defp resolve_agent_module(nil), do: ProCoder.Core.AgentFSM
  defp resolve_agent_module(mod) when is_atom(mod), do: mod
  defp resolve_agent_module(mod_str) when is_binary(mod_str) do
    trimmed = String.trim(mod_str)
    cond do
      trimmed == "" or trimmed == "ProCoder.Core.AgentFSM" ->
        ProCoder.Core.AgentFSM

      true ->
        # 1. Check Registry for specialist name
        case Registry.lookup(ProCoder.Registry, "specialist_#{trimmed}") do
          [{_pid, registered_mod}] when is_atom(registered_mod) ->
            registered_mod

          _ ->
            # 2. Try converting string to module atom
            try do
              parts = String.split(trimmed, ".") |> Enum.map(&String.to_atom/1)
              mod_alias = Module.concat(parts)
              if Code.ensure_loaded?(mod_alias) do
                mod_alias
              else
                # Try prefixing with ProCoder.Agents.Specialist.
                specialist_alias = Module.concat([ProCoder.Agents.Specialist, String.to_atom(trimmed)])
                if Code.ensure_loaded?(specialist_alias) do
                  specialist_alias
                else
                  mod_alias
                end
              end
            rescue
              _ -> ProCoder.Core.AgentFSM
            end
        end
    end
  end
end
