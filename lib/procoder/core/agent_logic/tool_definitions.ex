defmodule ProCoder.Core.AgentLogic.ToolDefinitions do
  @moduledoc """
  Single source of truth for all agent tool/function declarations.

  Each tool is a Gemini-compatible function declaration map with:
    - name: atom string matching perform_action/3 dispatch key
    - description: clear, terse guidance so the model picks the right tool
    - parameters: strongly-typed JSON Schema (per-tool, NOT shared)

  Usage:
    ToolDefinitions.all_tools()   -> list of function declaration maps
  """

  @custom_tools_table :procoder_custom_tools

  @doc "Returns the full list of function declarations for the Gemini/OpenAI tools API, including custom specialist skills."
  def all_tools do
    base = base_tools()
    custom = list_custom_tools()
    
    (base ++ custom)
    |> Enum.uniq_by(fn tool ->
      to_string(tool[:name] || tool["name"])
    end)
  end

  @doc "Returns the static base tool declarations."
  def base_tools do
    [
      read_file(),
      write_file(),
      patch_file(),
      run_in_source(),
      discovery_search(),
      query_database(),
      cdms_unified_query(),
      cdms_probe_node(),
      cdms_probe_edges(),
      cdms_time_travel(),
      recall_thought(),
      forge_agent(),
      spawn_worker(),
      add_planning_task(),
      add_planning_dependency(),
      get_next_task(),
      mark_task_complete(),
      transition_phase(),
      present_report(),
      submit_for_validation(),
      validator_approve(),
      validator_reject(),
      google_search(),
      load_skill(),
      install_skill(),
      run_skill_script(),
      read_skill_resource()
    ]
  end

  defp ensure_custom_tools_table do
    case :ets.info(@custom_tools_table) do
      :undefined ->
        try do
          :ets.new(@custom_tools_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          _ -> @custom_tools_table
        end
      _ ->
        @custom_tools_table
    end
  end

  @doc "Registers a custom tool declaration and its handler module."
  def register_custom_tool(tool_decl, handler_module) when is_map(tool_decl) do
    ensure_custom_tools_table()
    name = to_string(tool_decl[:name] || tool_decl["name"])
    :ets.insert(@custom_tools_table, {name, tool_decl, handler_module})
    :ok
  end

  @doc "Registers all skills exported by an agent module."
  def register_module_skills(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__tool_declarations__, 0) do
      declarations = module.__tool_declarations__()
      Enum.each(declarations, fn decl ->
        register_custom_tool(decl, module)
      end)
      :ok
    else
      :error
    end
  end

  @doc "Finds the handler module for a custom skill name."
  def get_skill_handler(skill_name) when is_binary(skill_name) do
    ensure_custom_tools_table()
    case :ets.lookup(@custom_tools_table, skill_name) do
      [{^skill_name, _decl, handler_module}] -> handler_module
      _ -> nil
    end
  end

  def get_skill_handler(skill_atom) when is_atom(skill_atom) do
    get_skill_handler(Atom.to_string(skill_atom))
  end

  @doc "Lists all registered custom tools."
  def list_custom_tools do
    ensure_custom_tools_table()
    :ets.tab2list(@custom_tools_table)
    |> Enum.map(fn {_name, decl, _handler} -> decl end)
  end

  # ---------------------------------------------------------------------------
  # Tool declarations
  # ---------------------------------------------------------------------------



  defp run_in_source do
    %{
      name: "run_in_source",
      description: """
      Executes a shell command directly in the root of the user's workspace.
      Use this exclusively for running codebase tools, testing scripts, starting processes, compiling, or manipulating files that require shell features (e.g. `chmod`).
      
      [CRITICAL INSTRUCTION] 
      DO NOT use this tool to simply `echo` out that you are finished or to announce mission completion. 
      You MUST use the `submit_for_validation` tool to conclude a mission. The validation instance will automatically reject your work if you try to finish a session by just echoing text via `run_in_source` because you are being lazy.

      Example Scenarios:
      1. Compile the real project: `mix compile`
      2. Run the full test suite: `mix test`
      3. Start the application interactively: `iex -S mix`
      4. Run migration: `mix ecto.migrate`
      5. Check formatting: `mix format`
      6. Run a specific mix task: `mix phx.server`

      This refers to the REAL source project root.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          cmd: %{
            type: "STRING",
            description: "The full command string to execute in the source root, e.g. \"mix test\" or \"iex -S mix\""
          },
          timeout: %{
            type: "INTEGER",
            description: "Optional timeout in seconds (default: 60). For long-running commands, use a higher value."
          }
        },
        required: ["cmd"]
      }
    }
  end

  defp read_file do
    %{
      name: "read_file",
      description: """
      Read the exact contents of a file from the agent worktree.
      Always prioritize this over `cat` in a shell command.
      
      Example Scenarios:
      1. Analyzing a module's implementation: `{"path": "lib/my_app/core.ex"}`
      2. Reading configuration files: `{"path": "config/dev.exs"}`
      3. Reviewing test cases: `{"path": "test/my_app/core_test.exs"}`
      4. Inspecting project definitions: `{"path": "mix.exs"}`
      5. Checking the README or documentation: `{"path": "README.md"}`
      
      Returns an error with guidance if the path does not exist or is a directory.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          path: %{
            type: "STRING",
            description: "Relative path from worktree root, e.g. \"lib/procoder/core/agent_logic/agent_fsm.ex\""
          }
        },
        required: ["path"]
      }
    }
  end

  defp write_file do
    %{
      name: "write_file",
      description: """
      Write or overwrite a file in the agent worktree (or the real source project if configured) IMMEDIATELY without review.
      Use this when you have the final, complete content ready for implementation.
      This is the standard tool for creating new files or replacing existing ones.
      Opens a diff in VS Code automatically.
      WARNING: Applies immediately.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          path: %{
            type: "STRING",
            description: "Relative path from worktree root, e.g. \"lib/app.ex\""
          },
          content: %{
            type: "STRING",
            description: "The complete new file content to write."
          }
        },
        required: ["path", "content"]
      }
    }
  end

  defp patch_file do
    %{
      name: "patch_file",
      description: """
      Apply a unified diff patch to an existing file in the agent worktree (or the real source project if configured) IMMEDIATELY without review.
      Use when you have a precise, minimal diff and are confident no review is needed.
      This is the standard tool for bug fixes and targeted logic updates.
      Opens a diff in VS Code automatically.
      WARNING: Applies immediately.
      
      CRITICAL PATCH FORMATTING RULES:
      - The diff string MUST be a perfectly valid unified diff.
      - CONTEXT LINES (unchanged lines) MUST start with a single space. DO NOT omit the leading space!
      - ADDED LINES MUST start with `+`.
      - REMOVED LINES MUST start with `-`.
      - Omitting the leading space on context lines is the most common cause of "malformed patch" errors. Pay close attention.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          path: %{
            type: "STRING",
            description: "Relative path of the file to patch, e.g. \"lib/app.ex\""
          },
          patch: %{
            type: "STRING",
            description: "Unified diff patch content (--- +++ @@ format)."
          }
        },
        required: ["path", "patch"]
      }
    }
  end


  defp discovery_search do
    %{
      name: "discovery_search",
      description: """
      Search the codebase using keyword or regex patterns.
      Use when you need to find where something IS DEFINED or USED across the entire project.
      
      Example Scenarios:
      1. Finding all usages of a specific function: `{"query": "def create_user"}`
      2. Locating where a config key is accessed: `{"query": "Application.get_env\\\\(:my_app, :secret"}`
      3. Searching for a specific error message string: `{"query": "Invalid user credentials"}`
      4. Finding all struct definitions in a context: `{"query": "defstruct \\\\["}`
      5. Searching for references to a specific module name: `{"query": "alias MyApp.Accounts.User"}`
      
      Do NOT use this more than 3 times in a row for the same concept; switch to query_database instead.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          query: %{
            type: "STRING",
            description: "Search keyword or regex pattern, e.g. \"defmodule.*AgentFSM\" or \"badkey\""
          }
        },
        required: ["query"]
      }
    }
  end
  # defp vector_search do
  #   %{
  #     name: "vector_search",
  #     description: """
  #     Search the codebase using semantic/vector embeddings.
  #     Use this when you are looking for CONCEPTS or FUNCTIONALITY rather than exact keywords.
  #     Vector search is better at finding related logic that might use different naming conventions.
  #     
  #     Example Scenarios:
  #     1. Finding where "authentication logic" resides.
  #     2. Locating "data persistence" or "caching" mechanisms.
  #     3. Searching for "error handling patterns" in the project.
  #     4. Finding "UI component rendering" logic.
  #     """,
  #     parameters: %{
  #       type: "OBJECT",
  #       properties: %{
  #         query: %{
  #           type: "STRING",
  #           description: "Natural language query describing the concept, e.g. \"how are users authenticated?\""
  #         }
  #       },
  #       required: ["query"]
  #     }
  #   }
  # end


  defp query_database do
    %{
      name: "query_database",
      description: """
      Semantically query the CodeGraph index for module relationships and dependencies.
      Use this when you need to understand the architecture, DEPENDENCIES, or CALLERS of a module, rather than just text matches.
      
      Example Scenarios:
      1. Finding all modules that depend on UserAuth: `{"operation": "list_relationships", "query": "MyApp.UserAuth", "type": "calls"}`
      2. Discovering the public API of a module: `{"operation": "describe_schema", "query": "MyApp.Accounts"}`
      3. Finding which module defines a specific function: `{"operation": "query_chunks", "query": "verify_password"}`
      4. Analyzing the dependencies of a core engine: `{"operation": "list_relationships", "query": "ProCoder.Core.Engine", "type": "depends_on"}`
      5. Fetching semantic documentation for a context: `{"operation": "query_chunks", "query": "Supervisor configuration guidelines"}`
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          operation: %{
            type: "STRING",
            description: "One of: query_chunks, list_relationships, describe_schema"
          },
          query: %{
            type: "STRING",
            description: "Module name or concept to query, e.g. \"AgentFSM\""
          },
          type: %{
            type: "STRING",
            description: "Relationship type filter: defines, calls, or depends_on"
          },
          limit: %{
            type: "INTEGER",
            description: "Max number of results (default 20)"
          }
        },
        required: ["operation", "query"]
      }
    }
  end

  defp recall_thought do
    %{
      name: "recall_thought",
      description: """
      Query your own past cognitive states from previous sessions (cross-session memory).
      Use when the goal involves past session context or what was done before.
      IMPORTANT: Every session is persisted. You can look back across sessions.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          session_id: %{
            type: "STRING",
            description: "The session ID to recall from, e.g. \"session_7\". Auto-filled with current session if omitted."
          },
          snapshot_id: %{
            type: "STRING",
            description: "Which snapshot to load: \"latest\" or a specific snapshot ID."
          }
        },
        required: ["snapshot_id"]
      }
    }
  end

  defp forge_agent do
    %{
      name: "forge_agent",
      description: """
      Synthesize, compile, and register a new specialist agent at runtime using the ProCoder Macro DSL.
      Use ANY TIME you are asked to create, build, or define a new agent or specialist.
      LIFECYCLE: forge_agent (COMPILE) → spawn_worker (EXECUTE). Always forge first, then spawn.

      DSL syntax:
        defagent AgentName do
          persona "..."
          defskill skill_name do
            # args map is implicit; return {:ok, value} or {:error, reason}
          end
        end
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          name: %{
            type: "STRING",
            description: "PascalCase agent name, e.g. \"SecurityAudit\""
          },
          goal_type: %{
            type: "STRING",
            description: "Short goal category, e.g. \"cybersecurity_vulnerability_scanning\""
          },
          dsl_code: %{
            type: "STRING",
            description: "Complete Elixir DSL source code for the agent."
          }
        },
        required: ["name", "goal_type", "dsl_code"]
      }
    }
  end

  defp spawn_worker do
    %{
      name: "spawn_worker",
      description: """
      Commission a parallel sub-agent or worker session.
      Use AFTER forge_agent to execute a forged specialist, or to parallelize analysis tasks.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          session_id: %{
            type: "STRING",
            description: "Unique ID for the new worker session, e.g. \"sub_task_analysis_1\""
          },
          goal: %{
            type: "STRING",
            description: "The sub-goal for this worker to accomplish."
          },
          module: %{
            type: "STRING",
            description: "Optional: fully-qualified Elixir module of a forged specialist, e.g. \"ProCoder.Agents.Specialist.SecurityAudit\""
          }
        },
        required: ["session_id", "goal"]
      }
    }
  end

  defp add_planning_task do
    %{
      name: "add_planning_task",
      description: """
      Register a task node in the global execution DAG.
      Use during PLANNING phase to structure the work breakdown before implementation.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          id: %{
            type: "STRING",
            description: "Unique task ID, e.g. \"task_discover_1\""
          },
          task_type: %{
            type: "STRING",
            description: "One of: root, discovery, planning, synthesis, verification"
          },
          payload: %{
            type: "OBJECT",
            description: "Task payload map, e.g. {\"description\": \"Map agent dependencies\"}",
            properties: %{
              description: %{type: "STRING"}
            }
          }
        },
        required: ["id", "task_type"]
      }
    }
  end

  defp add_planning_dependency do
    %{
      name: "add_planning_dependency",
      description: """
      Create a dependency edge between two DAG tasks (from → to).
      Use after adding tasks to establish execution ordering.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          from_id: %{
            type: "STRING",
            description: "ID of the prerequisite task."
          },
          to_id: %{
            type: "STRING",
            description: "ID of the dependent task that requires from_id to complete first."
          }
        },
        required: ["from_id", "to_id"]
      }
    }
  end

  defp transition_phase do
    %{
      name: "transition_phase",
      description: """
      Explicitly advance the agent to the next lifecycle phase.
      Phase order: discovery → planning → synthesis → verification.
      Once you are in the verification phase and have confirmed success, use the `finish` tool to complete the mission.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          phase: %{
            type: "STRING",
            description: "Target phase: discovery, planning, synthesis, or verification"
          }
        },
        required: ["phase"]
      }
    }
  end

  defp present_report do
    %{
      name: "present_report",
      description: """
      Create a Markdown report file and open it in the user's IDE (VS Code).
      Use when you want to show the user a substantial textual result, summary, or analysis.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          path: %{
            type: "STRING",
            description: "Relative path for the report file, e.g. \"reports/summary.md\""
          },
          content: %{
            type: "STRING",
            description: "Complete Markdown content for the report."
          }
        },
        required: ["path", "content"]
      }
    }
  end

  defp submit_for_validation do
    %{
      name: "submit_for_validation",
      description: """
      Signal that you believe the overall goal is successfully completed.
      You MUST follow the [PROTOCOL: REFLECTIVE GOAL MAPPING]:
      1. Copy the original goal text EXACTLY, word-for-word.
      2. For each line/requirement in the goal, provide a corresponding explanation and concrete proof of accomplishment (e.g., file paths, specific code changes, test results).
      Failure to follow this format exactly will result in immediate rejection by the Validator.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          rationale: %{
            type: "STRING",
            description: "A detailed explanation of why you believe all instructions in the goal have been exactly followed."
          },
          proof: %{
            type: "STRING",
            description: "Reflective Goal Mapping: The exact original goal text, with line-by-line explanations and proofs of work attached to each requirement."
          }
        },
        required: ["rationale", "proof"]
      }
    }
  end

  defp google_search do
    %{
      name: "google_search",
      description: """
      Perform a Google Search to find technical documentation, library specifications, or solutions to complex coding errors.
      Use this tool MANDATORILY when you encounter a compilation error, crash, or logic bug that you cannot resolve after a single attempt using codebase search alone.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          query: %{
            type: "STRING",
            description: "The technical search query, e.g. \"how to fix Elixir Request Timeout error?\""
          }
        },
        required: ["query"]
      }
    }
  end

  defp validator_approve do
    %{
      name: "validator_approve",
      description: """
      [VALIDATOR ONLY] Use this tool to approve the agent's proof of work if all conditions and aspects of the goal are fully met.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          message: %{
            type: "STRING",
            description: "A clear summary of what was accomplished and an approval message."
          }
        },
        required: ["message"]
      }
    }
  end

  defp validator_reject do
    %{
      name: "validator_reject",
      description: """
      [VALIDATOR ONLY] Use this tool to reject the agent's proof of work if any part of the goal is incomplete or unverified.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          feedback: %{
            type: "STRING",
            description: "Detailed actionable feedback explaining exactly what is missing and what the agent must do to fix it."
          }
        },
        required: ["feedback"]
      }
    }
  end

  defp get_next_task do
    %{
      name: "get_next_task",
      description: """
      Query the global DAG execution plan for the next available pending task.
      Use during the SYNTHESIS phase to fetch your next piece of work instead of waiting.
      Returns the task details or an error if no tasks are ready.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{},
        required: []
      }
    }
  end

  defp mark_task_complete do
    %{
      name: "mark_task_complete",
      description: """
      Mark a task from the global execution plan as completely finished.
      Use once you have verified that the task's goal has been achieved.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          task_id: %{
            type: "STRING",
            description: "The ID of the task that was completed, e.g. \"task_discover_1\""
          }
        },
        required: ["task_id"]
      }
    }
  end

  defp cdms_unified_query do
    %{
      name: "cdms_unified_query",
      description: """
      A high-precision tool for codebase understanding via the Cognitive Digital Modelling System (CDMS).
      It performs vector semantic, symbolic, and lexical text extraction simultaneously.
      Ideal for architectural mapping and exploring conceptual relationships.
      
      Examples:
      - `{"query": "Where is the logic that handles global system congestion?", "reasoning_mode": "semantic"}`
      - `{"query": "caching mechanisms", "reasoning_mode": "brainstorm"}`
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          query: %{
            type: "STRING",
            description: "The question, natural language query, or single token search term."
          },
          reasoning_mode: %{
            type: "STRING",
            description: "Optional reasoning mode. E.g. 'brainstorm' to multiply associative boosts across weaker semantic edges or 'semantic' for standard queries."
          }
        },
        required: ["query"]
      }
    }
  end

  defp cdms_probe_node do
    %{
      name: "cdms_probe_node",
      description: """
      Extract the cognitive anatomy (Summary, Why, Concepts) of a specific CDMS node. 
      Use this to understand the philosophical and structural role of a module.
      
      Example: Probe a 'SchemaManager' node ID to see its role in the database architecture.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          node_id: %{
            type: "STRING",
            description: "The precise UID of the node."
          }
        },
        required: ["node_id"]
      }
    }
  end

  defp cdms_probe_edges do
    %{
      name: "cdms_probe_edges",
      description: """
      Traverse the CDMS graph to find functional, semantic, hierarchical, and syntactic neighbors.
      Useful for tracing callers, dependencies, or logical 'siblings' of a module.
      
      Example: Probe edges for 'AuthSession' to find linked 'Guard' or 'Policy' modules.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          node_id: %{
            type: "STRING",
            description: "The source node ID to pivot from."
          }
        },
        required: ["node_id"]
      }
    }
  end

  defp cdms_time_travel do
    %{
      name: "cdms_time_travel",
      description: """
      Perform Forensic Chrono-Analysis of the project.
      Use this to see how code has mutated over time, reconstruct past file states, or search through historical vector states.
      Useful for debugging regressions or understanding the evolution of a logic branch.
      
      Actions:
      - 'mutations': See all CDMS graph changes in the last X minutes.
      - 'chrono': See the chronological version chain (diffs) of a specific node.
      - 'reconstruct': Get a file's content as it existed at a specific timestamp.
      - 'search_past': Run a semantic query against the codebase memory as it was 1 hour ago.
      
      Examples:
      - `{"action": "mutations", "time_param": "60m"}`: "What changed in the last hour?"
      - `{"action": "reconstruct", "node_id": "c83ef22a-...", "time_param": "2h"}`: "Show me this node 2 hours ago."
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          action: %{
            type: "STRING",
            description: "One of: mutations, chrono, reconstruct, search_past"
          },
          node_id: %{
            type: "STRING",
            description: "Required UID of the node if action is 'chrono' or 'reconstruct'"
          },
          time_param: %{
            type: "STRING",
            description: "Optional time value like '60m' (since 60min ago) or an ISO timestamp."
          },
          depth: %{
            type: "STRING",
            description: "Optional depth integer for 'chrono' action."
          },
          query: %{
            type: "STRING",
            description: "Optional query string if action is 'search_past'"
          }
        },
        required: ["action", "time_param"]
      }
    }
  end

  defp load_skill do
    %{
      name: "load_skill",
      description: """
      Phase 2 Progressive Disclosure: Activates and reads the full instructions, guidelines,
      and reference index of a discovered skill (e.g. from skills manifest or user directive).
      Call this when a task matches a skill's description or when instructed by the user.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          skill_name: %{
            type: "STRING",
            description: "The exact name of the skill to activate and read (e.g. 'biquote-api', 'circle-agent-stack')."
          }
        },
        required: ["skill_name"]
      }
    }
  end

  defp install_skill do
    %{
      name: "install_skill",
      description: """
      Installs a Claude/Codex skill from a Git repository or public HTTP URL into project
      or global skills directory.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          source: %{
            type: "STRING",
            description: "Git repository URL (e.g. 'https://github.com/org/repo.git') or public URL/local folder path to install from."
          },
          scope: %{
            type: "STRING",
            description: "Installation scope: 'project' (installs in workspace .claude/skills) or 'global' (installs in ~/.claude/skills). Defaults to 'project'."
          },
          name: %{
            type: "STRING",
            description: "Optional custom name for the skill directory."
          }
        },
        required: ["source"]
      }
    }
  end

  defp run_skill_script do
    %{
      name: "run_skill_script",
      description: """
      Phase 3 Progressive Disclosure: Executes a bundled executable script inside a skill's scripts/
      directory under system security and policy engine controls.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          skill_name: %{
            type: "STRING",
            description: "Name of the skill owning the script."
          },
          script_name: %{
            type: "STRING",
            description: "Relative path or filename of the executable script inside the skill's scripts/ directory."
          },
          args: %{
            type: "ARRAY",
            items: %{type: "STRING"},
            description: "List of string arguments to pass to the script."
          }
        },
        required: ["skill_name", "script_name"]
      }
    }
  end

  defp read_skill_resource do
    %{
      name: "read_skill_resource",
      description: """
      Phase 3 Progressive Disclosure: Reads an on-demand reference document, template, or asset
      located in a skill's references/ or resources/ directory without loading unnecessary bulk context upfront.
      """,
      parameters: %{
        type: "OBJECT",
        properties: %{
          skill_name: %{
            type: "STRING",
            description: "Name of the skill."
          },
          resource_path: %{
            type: "STRING",
            description: "Relative path inside the skill directory (e.g. 'references/api_reference.md', 'examples/quickstart.ex')."
          }
        },
        required: ["skill_name", "resource_path"]
      }
    }
  end
end

