defmodule ProCoder.Tests.ExternalSkillsProgressiveDisclosureTest do
  @moduledoc """
  Validates that:
  1. ToolDefinitions includes the Claude/Codex progressive disclosure tools:
     - load_skill
     - install_skill
     - run_skill_script
     - read_skill_resource
  2. Phase 1 (Discovery): ExternalSkillRegistry scans skills across user and workspace roots
     and generates a lightweight markdown manifest for the system prompt.
  3. Phase 2 (Activation): ExternalSkillRegistry loads the full SKILL.md body and instructions on demand.
  4. Phase 3 (Execution): ExternalSkillRegistry executes bundled scripts and reads resources safely.
  5. TUI Directives: CommandRouter correctly routes /skills and /skill commands,
     and allows directing an active agent process to read/adopt a skill.
  """

  alias ProCoder.Skills.ExternalSkillRegistry
  alias ProCoder.Core.AgentLogic.ToolDefinitions
  alias ProCoder.UI.RoutingLayer.CommandRouter

  def run do
    IO.puts("\n=== ProCoder Claude/Codex Skills Progressive Disclosure Integration Test ===")

    # Ensure supervisor or process is alive
    unless Process.whereis(ExternalSkillRegistry) do
      {:ok, _} = ExternalSkillRegistry.start_link([])
    end

    unless Process.whereis(CommandRouter) do
      {:ok, _} = CommandRouter.start_link([])
    end

    # 1. Verify ToolDefinitions has progressive disclosure tools
    IO.puts("\n[Step 1] Checking ToolDefinitions for progressive disclosure tools...")
    tools = ToolDefinitions.all_tools()
    tool_names = Enum.map(tools, &(&1[:name] || &1["name"]))

    assert_true("load_skill" in tool_names, "load_skill must be present in all_tools")
    assert_true("install_skill" in tool_names, "install_skill must be present in all_tools")
    assert_true("run_skill_script" in tool_names, "run_skill_script must be present in all_tools")
    assert_true("read_skill_resource" in tool_names, "read_skill_resource must be present in all_tools")

    load_tool = Enum.find(tools, &((&1[:name] || &1["name"]) == "load_skill"))
    assert_true(load_tool.parameters.required == ["skill_name"], "load_skill requires skill_name")
    IO.puts("  ✓ All 4 tool declarations verified in ToolDefinitions.")

    # 2. Phase 1: Discovery
    IO.puts("\n[Step 2] Phase 1 (Discovery): Scanning skills and producing compact manifest...")
    skills = ExternalSkillRegistry.list_skills()
    IO.puts("  Found #{length(skills)} external skills in system directories.")
    assert_true(length(skills) > 0, "ExternalSkillRegistry must discover existing skills")

    sample_skill = List.first(skills)
    IO.puts("  Sample discovered skill: #{sample_skill.name} (#{sample_skill.scope})")
    assert_true(is_binary(sample_skill.name), "Skill name must be a string")
    assert_true(is_binary(sample_skill.description), "Skill description must be a string")
    assert_true(File.regular?(sample_skill.path), "Skill path must be a valid file (SKILL.md)")
    assert_true(File.dir?(sample_skill.dir), "Skill dir must be a valid directory")

    manifest = ExternalSkillRegistry.compact_manifest(File.cwd!())
    assert_true(is_binary(manifest), "Manifest must be a string")
    assert_true(String.contains?(manifest, "### DISCOVERED EXTERNAL SKILLS"), "Manifest header present")
    assert_true(String.contains?(manifest, "PROGRESSIVE DISCLOSURE PROTOCOL"), "Progressive disclosure protocol present")
    assert_true(String.contains?(manifest, "load_skill"), "Manifest instructs agent on load_skill")
    assert_true(String.contains?(manifest, sample_skill.name), "Manifest includes discovered skill name")
    IO.puts("  ✓ Phase 1 Discovery manifest verified.")

    # 3. Phase 2: Activation
    IO.puts("\n[Step 3] Phase 2 (Activation): Loading full instructions on demand...")
    {:ok, full_instructions} = ExternalSkillRegistry.load_skill_content(sample_skill.name)
    assert_true(is_binary(full_instructions), "Loaded instructions must be a string")
    assert_true(byte_size(full_instructions) > 100, "Loaded instructions must contain substantial content")
    assert_true(String.contains?(full_instructions, sample_skill.name), "Loaded instructions must include skill name")
    IO.puts("  ✓ Phase 2 Activation loaded #{byte_size(full_instructions)} bytes for '#{sample_skill.name}'.")

    # 4. Phase 3: Execution (bundled resources and scripts)
    IO.puts("\n[Step 4] Phase 3 (Execution): Testing bundled resources & scripts...")
    tmp_skill_dir = Path.join([File.cwd!(), ".claude", "skills", "test-demo-skill"])
    File.mkdir_p!(Path.join(tmp_skill_dir, "references"))
    File.mkdir_p!(Path.join(tmp_skill_dir, "scripts"))

    skill_md = """
    ---
    name: test-demo-skill
    description: A temporary test skill for progressive disclosure validation
    allowed-tools:
      - read_file
      - write_file
    ---
    # Test Demo Skill
    Detailed instructions for test demo skill.
    """
    File.write!(Path.join(tmp_skill_dir, "SKILL.md"), skill_md)

    ref_content = "# API Reference Guide\nDetailed endpoint definitions."
    File.write!(Path.join([tmp_skill_dir, "references", "guide.md"]), ref_content)

    script_content = "#!/bin/sh\necho \"Executed skill script with arg: $1\"\n"
    script_path = Path.join([tmp_skill_dir, "scripts", "run.sh"])
    File.write!(script_path, script_content)
    File.chmod!(script_path, 0o755)

    # Rescan to discover the new skill
    ExternalSkillRegistry.rescan()
    test_skill = ExternalSkillRegistry.get_skill("test-demo-skill")
    assert_true(test_skill != nil, "Registry must discover test-demo-skill")

    # Read reference resource
    {:ok, read_ref} = ExternalSkillRegistry.read_skill_resource("test-demo-skill", "references/guide.md")
    assert_true(read_ref == ref_content, "read_skill_resource must return exact resource content")
    IO.puts("  ✓ Resource file successfully read from references/guide.md")

    # Execute bundled script
    {:ok, script_output} = ExternalSkillRegistry.execute_skill_script("test-demo-skill", "run.sh", ["ProCoderV2"], File.cwd!())
    assert_true(String.contains?(script_output, "Executed skill script with arg: ProCoderV2"), "Script output must contain arg")
    IO.puts("  ✓ Script execution succeeded: #{String.trim(script_output)}")

    # Clean up temporary test skill
    File.rm_rf!(tmp_skill_dir)
    ExternalSkillRegistry.rescan()

    # 5. TUI Directives & CommandRouter dispatch
    IO.puts("\n[Step 5] TUI Directives & CommandRouter dispatching...")
    
    # 5.1 /skills
    assert_true(match?({:ok, {:skills_list, _}}, CommandRouter.dispatch(:skills, %{subcommand: "list"})), "CommandRouter /skills list must succeed")
    IO.puts("  ✓ /skills list dispatched successfully")

    # 5.2 /skills reload
    assert_true(match?({:ok, :skills_reloaded}, CommandRouter.dispatch(:skills, %{subcommand: "reload"})), "CommandRouter /skills reload must succeed")
    IO.puts("  ✓ /skills reload dispatched successfully")

    # 5.3 /skill read without active agent -> preview
    sample_skill_name = sample_skill.name
    assert_true(match?({:ok, {:skill_preview, ^sample_skill_name, _}}, 
      CommandRouter.dispatch(:skill, %{action: "read", target: sample_skill.name, pid: nil})), 
      "CommandRouter /skill read without agent must preview skill")
    IO.puts("  ✓ /skill read (preview mode) dispatched successfully")

    # 5.4 /skill read with active agent -> tells agent to read skill
    test_agent_pid = spawn(fn ->
      receive do
        {:"$gen_cast", {:user_input, directive}} ->
          IO.puts("  [Agent Process Mock] Received directive: #{String.slice(directive, 0, 50)}...")
      after
        3000 -> :ok
      end
    end)

    assert_true(match?({:ok, {:skill_read_directed, ^sample_skill_name}}, 
      CommandRouter.dispatch(:skill, %{action: "read", target: sample_skill.name, pid: test_agent_pid})), 
      "CommandRouter /skill read with agent must direct agent")
    IO.puts("  ✓ /skill read directed agent to adopt skill successfully")

    IO.puts("\n🎉 ALL CHECKS PASSED: The Three-Phase Progressive Disclosure Pattern & TUI Control are fully functional!")
  end

  defp assert_true(true, _msg), do: :ok
  defp assert_true(false, msg) do
    IO.puts("❌ ASSERTION FAILED: #{msg}")
    raise "TestAssertionError: #{msg}"
  end
end

ProCoder.Tests.ExternalSkillsProgressiveDisclosureTest.run()
