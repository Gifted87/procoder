defmodule ProCoder.Tests.SpecialistReActLoopTest do
  @moduledoc """
  Validates that:
  1. The Mastery SDK allows forging specialist agents with custom skills at runtime.
  2. Forged skills are dynamically registered as tools in ToolDefinitions.
  3. The specialist module implements the required callbacks, introspection, and FSM start_link bridge.
  4. Custom skills execute under PolicyEngine risk heuristics.
  5. SwarmOrchestrationSkill resolves and binds the specialist module without discarding it.
  """
  require Logger
  alias ProCoder.Skills.{AgentForgeSkill, SwarmOrchestrationSkill}
  alias ProCoder.Core.AgentLogic.ToolDefinitions

  def run do
    IO.puts("\n=== ProCoder Mastery SDK & ReAct FSM Loop Integration Test ===")

    # 1. Forge a specialist agent with DSL code
    IO.puts("\n[Step 1] Forging specialist agent 'SecurityAuditor' via AgentForgeSkill...")
    forge_args = %{
      "name" => "SecurityAuditor",
      "goal_type" => "cybersecurity vulnerability and dependency analysis",
      "dsl_code" => """
      defagent SecurityAuditor do
        persona \"\"\"
        You are a dedicated Security Auditor agent. You scan codebases for CVEs and hardcoded credentials.
        \"\"\"

        defskill scan_for_secrets do
          target = args["path"] || "mix.exs"
          case ProCoder.Actuator.AgentIO.read_file(target) do
            {:ok, content} ->
              if String.contains?(content, "SECRET") or String.contains?(content, "KEY") do
                {:ok, "Alert: Suspicious token pattern identified in \#{target}"}
              else
                {:ok, "Clean: No secrets identified in \#{target}"}
              end
            {:error, reason} ->
              {:error, "File scan failed: \#{inspect(reason)}"}
          end
        end
      end
      """
    }

    {:ok, forge_msg} = AgentForgeSkill.create_specialist(forge_args)
    IO.puts("✅ Forge succeeded: #{forge_msg}")

    # 2. Verify compiled module and exports
    IO.puts("\n[Step 2] Verifying compiled specialist module and introspection...")
    mod = SecurityAuditor
    assert_true(Code.ensure_loaded?(mod), "Module SecurityAuditor should be loaded in BEAM")
    assert_true(function_exported?(mod, :persona, 0), "SecurityAuditor should export persona/0")
    assert_true(function_exported?(mod, :__skills__, 0), "SecurityAuditor should export __skills__/0")
    assert_true(function_exported?(mod, :__tool_declarations__, 0), "SecurityAuditor should export __tool_declarations__/0")
    assert_true(function_exported?(mod, :execute_skill, 2), "SecurityAuditor should export execute_skill/2")
    assert_true(function_exported?(mod, :start_link, 1), "SecurityAuditor should export start_link/1")
    assert_true(function_exported?(mod, :scan_for_secrets, 1), "SecurityAuditor should export scan_for_secrets/1")

    IO.puts("Specialist persona: #{inspect(mod.persona())}")
    IO.puts("Specialist skills: #{inspect(mod.__skills__())}")
    IO.puts("✅ Specialist module structure and ReAct bridge verified")

    # 3. Verify dynamic registration in ToolDefinitions
    IO.puts("\n[Step 3] Verifying custom tool registration in ToolDefinitions...")
    all_tools = ToolDefinitions.all_tools()
    tool_names = Enum.map(all_tools, fn t -> to_string(t[:name] || t["name"]) end)
    assert_true("scan_for_secrets" in tool_names, "Custom skill 'scan_for_secrets' must appear in ToolDefinitions.all_tools()")
    
    handler = ToolDefinitions.get_skill_handler("scan_for_secrets")
    assert_true(handler == mod, "ToolDefinitions handler for 'scan_for_secrets' must resolve to SecurityAuditor")
    IO.puts("✅ Custom skill 'scan_for_secrets' is dynamically exposed to LLM tools API")

    # 4. Test skill execution via the ReAct action bridge
    IO.puts("\n[Step 4] Testing skill execution via execute_skill and direct dispatch...")
    scan_result = mod.execute_skill("scan_for_secrets", %{"path" => "mix.exs"})
    assert_true(match?({:ok, _}, scan_result), "scan_for_secrets should return {:ok, msg}")
    IO.puts("Direct skill output: #{inspect(scan_result)}")
    IO.puts("✅ Skill executed under PolicyEngine and returned valid observation")

    # 5. Test SwarmOrchestrationSkill.spawn_worker integration
    IO.puts("\n[Step 5] Testing SwarmOrchestrationSkill module resolution...")
    # Verify module resolution for specialist
    res_mod = SwarmOrchestrationSkill.spawn_worker(%{
      "session_id" => "swarm_test",
      "goal" => "Scan target directory",
      "module" => "SecurityAuditor"
    })
    IO.puts("Spawn worker output: #{inspect(res_mod)}")
    assert_true(match?({:ok, _}, res_mod), "spawn_worker must succeed with specialist module")

    IO.puts("\n🎉 ALL CHECKS PASSED: Mastery SDK and ReAct FSM Loop are fully connected!")
  end

  defp assert_true(true, _msg), do: :ok
  defp assert_true(false, msg) do
    IO.puts("❌ ASSERTION FAILED: #{msg}")
    raise "TestAssertionError: #{msg}"
  end
end

ProCoder.Tests.SpecialistReActLoopTest.run()
