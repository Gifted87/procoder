defmodule ProCoder.Skills.AgentForgeSkill do
  @moduledoc """
  Skill for dynamic agent creation and runtime compilation.
  Enables the agent to build new specialists using ProCoder's Macro DSL.
  """
  require Logger

  @doc """
  Generates and compiles a new agent module at runtime.
  """
  def create_specialist(args) do
    name = args["name"]
    goal_type = args["goal_type"]
    tools = Map.get(args, "tools", ["read_file", "write_file"])
    custom_code = args["dsl_code"]

    module_name = "ProCoder.Agents.Specialist.#{name}"
    
    code = custom_code || """
    defmodule #{module_name} do
      import ProCoder.SDK.MacroDSL.Agents.AgentMacro
      
      defagent Specialist do
        persona \"\"\"
        You are a specialized ProCoder agent focused on #{goal_type}.
        You have access to the following tools: #{Enum.join(tools, ", ")}.
        \"\"\"
      end
    end
    """

    # For safety in this environment, we'll write it to a file and then compile
    file_path = "/tmp/#{name}_agent.ex"
    File.write!(file_path, code)
    
    try do
      Code.compile_file(file_path)
      Logger.info("Forge: Compiled new agent module: #{module_name}")
      {:ok, "Specialist agent '#{name}' has been forged and compiled. Module: #{module_name}"}
    rescue
      e -> {:error, "Forge failed: #{inspect(e)}"}
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
    session_id = args["session_id"]
    sub_session_id = "#{session_id}_worker_#{:erlang.unique_integer([:positive])}"
    goal = args["goal"]
    # We default to the standard AgentFSM unless a specialist type is provided
    _type = Map.get(args, "module", "ProCoder.Core.AgentFSM")

    case SessionManager.spawn_agent(sub_session_id, goal) do
      {:ok, pid} ->
        {:ok, "Worker spawned successfully [ID: #{sub_session_id}, PID: #{inspect(pid)}]. Tasking initiated."}
      {:error, reason} ->
        {:error, "Failed to spawn worker: #{inspect(reason)}"}
    end
  end
end
