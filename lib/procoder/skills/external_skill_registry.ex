defmodule ProCoder.Skills.ExternalSkillRegistry do
  @moduledoc """
  The ExternalSkillRegistry implements the Three-Phase "Progressive Disclosure" pattern
  for Claude Code, Codex, and Agent Skills (SKILL.md standard).

  Phases:
  1. Discovery: Scans directories at boot time and extracts YAML frontmatter (name + description).
     Generates a lightweight manifest (~30-50 tokens/skill) injected into the prompt.
  2. Activation: Dynamically loads the full markdown instructions on demand via the `load_skill`
     tool or via TUI user slash command `/skill read <skill_name>`.
  3. Execution: Resolves lazy-loaded reference documents (`references/`) and executes automation
     scripts (`scripts/`) under PolicyEngine evaluation.
  """

  use GenServer
  require Logger

  alias ProCoder.Actuator.PolicyLogic.PolicyEngine

  @table_name :procoder_external_skills

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Re-scans all global and workspace skill paths and updates ETS index."
  def rescan(workspace_root \\ nil) do
    GenServer.call(__MODULE__, {:rescan, workspace_root})
  end

  @doc "Lists all registered external skills metadata (without full markdown bodies)."
  def list_skills do
    ensure_table()
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_name, meta} -> meta end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Retrieves metadata for a specific skill by name."
  def get_skill(skill_name) when is_binary(skill_name) do
    ensure_table()
    case :ets.lookup(@table_name, skill_name) do
      [{^skill_name, meta}] -> {:ok, meta}
      _ -> {:error, :not_found}
    end
  end

  @doc "Phase 1: Generates the lightweight manifest string for prompt injection."
  def compact_manifest(_workspace_root \\ nil) do
    skills = list_skills()
    if skills == [] do
      ""
    else
      lines = Enum.map(skills, fn s ->
        desc = s.description |> String.replace("\n", " ") |> String.slice(0, 180)
        "- #{s.name} [#{s.scope}]: #{desc}"
      end)

      """
      ### DISCOVERED EXTERNAL SKILLS (Claude / Codex Standard):
      #{Enum.join(lines, "\n")}

      [PROGRESSIVE DISCLOSURE PROTOCOL]
      The above skills provide specialized workflows and guidelines.
      To activate and read the full instructions for any skill, call tool `load_skill({"skill_name": "<name>"})`.
      """
    end
  end

  @doc "Phase 2: Reads and activates the complete SKILL.md body and resources."
  def load_skill_content(skill_name) when is_binary(skill_name) do
    case get_skill(skill_name) do
      {:ok, meta} ->
        case File.read(meta.path) do
          {:ok, raw_content} ->
            {_frontmatter, body} = extract_frontmatter(raw_content)

            scripts_manifest =
              if meta.scripts != [] do
                "\n\nBundled automation scripts (run via `run_skill_script`):\n" <>
                  Enum.map_join(meta.scripts, "\n", fn script ->
                    "- #{script}"
                  end)
              else
                ""
              end

            references_manifest =
              if meta.references != [] do
                "\n\nAdditional reference manuals (read via `read_skill_resource`):\n" <>
                  Enum.map_join(meta.references, "\n", fn ref ->
                    "- #{ref}"
                  end)
              else
                ""
              end

            full_payload = """
            # SKILL: #{meta.name}
            Description: #{meta.description}
            Compatibility: #{meta.compatibility || "Unspecified"}
            Path: #{meta.path}
            #{scripts_manifest}
            #{references_manifest}

            ---
            ## OPERATIONAL INSTRUCTIONS:
            #{body}
            """
            {:ok, full_payload}

          {:error, reason} ->
            {:error, "Failed to read skill at #{meta.path}: #{inspect(reason)}"}
        end

      {:error, :not_found} ->
        {:error, "Skill '#{skill_name}' not found. Available skills: #{inspect(Enum.map(list_skills(), & &1.name))}"}
    end
  end

  @doc "Phase 3: Executes an automation script from the skill's scripts/ directory."
  def execute_skill_script(skill_name, script_name, args, workspace_root \\ nil) do
    case get_skill(skill_name) do
      {:ok, meta} ->
        script_path = Path.join([meta.dir, "scripts", script_name])
        if File.exists?(script_path) do
          # Evaluate risk via PolicyEngine
          policy_res = PolicyEngine.evaluate_action(%{
            type: :shell,
            cmd: "run_skill_script:#{script_name}",
            risk: 0.2,
            uncertainty: 0.1,
            repetition: 0,
            idle_time_ms: 0
          })

          case policy_res do
            :suspend ->
              {:error, "Script '#{script_name}' execution suspended by PolicyEngine."}

            _ ->
              cwd = workspace_root || File.cwd!()
              args_list = if is_list(args), do: Enum.map(args, &to_string/1), else: []
              File.chmod(script_path, 0o755)

              cmd_result =
                cond do
                  String.ends_with?(script_name, ".py") ->
                    System.cmd("python3", [script_path | args_list], cd: cwd, stderr_to_stdout: true)

                  String.ends_with?(script_name, ".js") ->
                    System.cmd("node", [script_path | args_list], cd: cwd, stderr_to_stdout: true)

                  String.ends_with?(script_name, ".sh") ->
                    System.cmd("bash", [script_path | args_list], cd: cwd, stderr_to_stdout: true)

                  true ->
                    System.cmd(script_path, args_list, cd: cwd, stderr_to_stdout: true)
                end

              case cmd_result do
                {output, 0} -> {:ok, output}
                {output, code} -> {:error, "Script exited with code #{code}:\n#{output}"}
              end
          end
        else
          {:error, "Script '#{script_name}' not found in #{Path.join(meta.dir, "scripts")}. Available: #{inspect(meta.scripts)}"}
        end

      error -> error
    end
  end

  @doc "Phase 3: Reads a supplemental reference document from references/."
  def read_skill_resource(skill_name, resource_rel_path) do
    case get_skill(skill_name) do
      {:ok, meta} ->
        full_path = Path.join(meta.dir, resource_rel_path)
        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Failed to read resource #{resource_rel_path}: #{inspect(reason)}"}
        end
      error -> error
    end
  end

  @doc "Instructs the active agent process to read and apply a specific skill immediately."
  def tell_agent_read_skill(agent_pid, skill_name) when is_pid(agent_pid) and is_binary(skill_name) do
    case load_skill_content(skill_name) do
      {:ok, skill_content} ->
        directive = """
        [HIGH SALIENCE USER DIRECTIVE: LOAD AND APPLY SKILL]
        The user has commanded you to immediately read, prioritize, and adhere to the following external skill:
        #{skill_content}

        Acknowledge receipt of this skill and immediately integrate its workflows, guidelines, and rules into your current task.
        """

        # Cast user directive message to AgentFSM
        GenServer.cast(agent_pid, {:user_input, directive})
        {:ok, "Skill '#{skill_name}' instructions dispatched to active agent."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Installs an external skill from a GitHub repository or URL."
  def install_skill(source, opts \\ []) do
    scope = Keyword.get(opts, :scope, :project)
    workspace_root = Keyword.get(opts, :workspace_root) || Application.get_env(:procoder, ProCoder.SessionManager)[:source_root] || File.cwd!()

    target_base = 
      if scope == :global do
        Path.expand("~/.claude/skills")
      else
        Path.join(workspace_root, ".claude/skills")
      end

    File.mkdir_p!(target_base)

    clean_source = String.trim(source)

    res =
      cond do
        # 1. Direct URL to raw SKILL.md
        String.ends_with?(clean_source, "SKILL.md") or String.starts_with?(clean_source, "http") ->
          install_from_url(clean_source, target_base, opts[:name])

        # 2. GitHub shorthand "owner/repo" or "owner/repo/skill-name"
        Regex.match?(~r/^[\w\-\.]+\/[\w\-\.]+$/, clean_source) ->
          install_from_github(clean_source, target_base, opts[:name])

        # 3. Local directory path
        File.dir?(clean_source) ->
          install_from_local_dir(clean_source, target_base)

        true ->
          {:error, "Unsupported skill source: #{clean_source}. Expected GitHub 'owner/repo' or raw URL."}
      end

    # Rescan after installation
    rescan(workspace_root)
    res
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    ensure_table()
    source_root = Application.get_env(:procoder, ProCoder.SessionManager)[:source_root] || File.cwd!()
    do_rescan(source_root)
    {:ok, %{workspace_root: source_root}}
  end

  @impl true
  def handle_call({:rescan, workspace_root}, _from, state) do
    ws = workspace_root || state.workspace_root
    count = do_rescan(ws)
    {:reply, {:ok, count}, %{state | workspace_root: ws}}
  end

  # --- Internal Helpers ---

  defp ensure_table do
    case :ets.info(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        rescue
          _ -> @table_name
        end
      _ ->
        @table_name
    end
  end

  defp do_rescan(workspace_root) do
    ensure_table()
    :ets.delete_all_objects(@table_name)

    directories = [
      {Path.expand("~/.gemini/config/skills"), :global},
      {Path.expand("~/.claude/skills"), :global},
      {Path.expand("~/.procoder/skills"), :global},
      {Path.expand("~/.agents/skills"), :global}
    ] ++ 
    if workspace_root do
      [
        {Path.join(workspace_root, ".claude/skills"), :workspace},
        {Path.join(workspace_root, ".agents/skills"), :workspace},
        {Path.join(workspace_root, "skills"), :workspace},
        {Path.join(workspace_root, ".procoder/skills"), :workspace}
      ]
    else
      []
    end

    total_scanned =
      Enum.reduce(directories, 0, fn {dir, scope}, acc ->
        if File.dir?(dir) do
          case File.ls(dir) do
            {:ok, entries} ->
              entries_count = 
                Enum.reduce(entries, 0, fn entry, entry_acc ->
                  skill_dir = Path.join(dir, entry)
                  skill_file = Path.join(skill_dir, "SKILL.md")

                  if File.regular?(skill_file) do
                    case parse_skill_file(skill_file, skill_dir, scope) do
                      {:ok, meta} ->
                        :ets.insert(@table_name, {meta.name, meta})
                        entry_acc + 1
                      _ ->
                        entry_acc
                    end
                  else
                    entry_acc
                  end
                end)
              acc + entries_count
            _ -> acc
          end
        else
          acc
        end
      end)

    Logger.info("[ExternalSkillRegistry] Discovered and indexed #{total_scanned} skills across global and workspace directories.")
    total_scanned
  end

  defp parse_skill_file(skill_file, skill_dir, scope) do
    case File.read(skill_file) do
      {:ok, content} ->
        {frontmatter, body} = extract_frontmatter(content)
        dir_name = Path.basename(skill_dir)
        name = frontmatter["name"] || dir_name
        description = frontmatter["description"] || "Skill defined in #{dir_name}"

        scripts_dir = Path.join(skill_dir, "scripts")
        scripts = if File.dir?(scripts_dir), do: File.ls!(scripts_dir), else: []

        refs_dir = Path.join(skill_dir, "references")
        refs = if File.dir?(refs_dir), do: File.ls!(refs_dir), else: []

        meta = %{
          name: name,
          description: description,
          path: skill_file,
          dir: skill_dir,
          scope: scope,
          compatibility: frontmatter["compatibility"],
          allowed_tools: frontmatter["allowed-tools"] || frontmatter["allowed_tools"],
          instructions: body,
          scripts: scripts,
          references: refs,
          raw_frontmatter: frontmatter
        }
        {:ok, meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Lightweight robust YAML frontmatter extractor
  defp extract_frontmatter(content) do
    trimmed = String.trim_leading(content)
    if String.starts_with?(trimmed, "---") do
      lines = String.split(trimmed, "\n")
      # Drop the initial "---"
      [_first | rest] = lines

      # Find index of closing "---"
      case Enum.split_while(rest, fn line -> String.trim(line) != "---" end) do
        {yaml_lines, ["---" | body_lines]} ->
          frontmatter = parse_simple_yaml(yaml_lines)
          body = Enum.join(body_lines, "\n") |> String.trim()
          {frontmatter, body}
        _ ->
          {%{}, content}
      end
    else
      {%{}, content}
    end
  end

  defp parse_simple_yaml(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      trimmed = String.trim(line)
      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          acc

        String.contains?(trimmed, ":") ->
          [key | rest] = String.split(trimmed, ":", parts: 2)
          clean_key = String.trim(key)
          raw_val = Enum.join(rest, ":") |> String.trim()
          clean_val = 
            raw_val
            |> String.replace_prefix("\"", "")
            |> String.replace_suffix("\"", "")
            |> String.replace_prefix("'", "")
            |> String.replace_suffix("'", "")

          Map.put(acc, clean_key, clean_val)

        true ->
          acc
      end
    end)
  end

  defp install_from_url(url, target_base, optional_name) do
    Logger.info("[SkillInstaller] Fetching skill from URL: #{url}")
    # Using httpc / inets or curl
    tmp_file = "/tmp/skill_download_#{:erlang.unique_integer([:positive])}.md"
    case System.cmd("curl", ["-sSL", url, "-o", tmp_file]) do
      {_, 0} ->
        case File.read(tmp_file) do
          {:ok, content} ->
            {frontmatter, _body} = extract_frontmatter(content)
            skill_name = optional_name || frontmatter["name"] || "skill_#{:erlang.unique_integer([:positive])}"
            dest_dir = Path.join(target_base, skill_name)
            File.mkdir_p!(dest_dir)
            File.cp!(tmp_file, Path.join(dest_dir, "SKILL.md"))
            File.rm(tmp_file)
            {:ok, "Skill '#{skill_name}' installed to #{dest_dir}"}
          {:error, err} ->
            {:error, "Downloaded file unreadable: #{inspect(err)}"}
        end
      {err, _} ->
        {:error, "Failed downloading from #{url}: #{err}"}
    end
  end

  defp install_from_github(repo, target_base, optional_name) do
    skill_name = optional_name || List.last(String.split(repo, "/"))
    dest_dir = Path.join(target_base, skill_name)

    # If npx is available, try npx skills add
    if System.find_executable("npx") do
      Logger.info("[SkillInstaller] Installing via npx skills: #{repo}")
      case System.cmd("npx", ["-y", "skills", "add", repo, "-a", "claude-code", "--dir", target_base]) do
        {_out, 0} ->
          {:ok, "Skill '#{skill_name}' installed via npx skills."}
        _ ->
          git_clone_fallback(repo, dest_dir, skill_name)
      end
    else
      git_clone_fallback(repo, dest_dir, skill_name)
    end
  end

  defp git_clone_fallback(repo, dest_dir, skill_name) do
    git_url = "https://github.com/#{repo}.git"
    Logger.info("[SkillInstaller] Cloning skill repository: #{git_url}")
    File.rm_rf!(dest_dir)
    case System.cmd("git", ["clone", "--depth", "1", git_url, dest_dir]) do
      {_, 0} ->
        {:ok, "Skill '#{skill_name}' cloned from #{repo}."}
      {err, code} ->
        {:error, "Git clone failed (exit #{code}): #{err}"}
    end
  end

  defp install_from_local_dir(source_dir, target_base) do
    name = Path.basename(source_dir)
    dest_dir = Path.join(target_base, name)
    File.cp_r!(source_dir, dest_dir)
    {:ok, "Skill '#{name}' copied from local directory to #{dest_dir}."}
  end
end
