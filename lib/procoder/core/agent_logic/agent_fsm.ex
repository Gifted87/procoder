defmodule ProCoder.Core.AgentFSM do
  @moduledoc """
  The primary cognitive controller for an individual autonomous coding agent.
  Implements a gen_statem to manage transitions across the agent lifecycle.

  Tool use is powered by an OpenAI-compatible Chat Completions API:
    - The adapter sends all tools as typed OpenAI function tools.
    - Each LLM turn returns {:ok, %{thought: t, tool_calls: [{name, args}]}} —
      zero JSON parsing required.
    - Multiple tool calls per turn are dispatched via execute_batch / verify_batch
      FSM events, enabling true multi-tool sequencing.
  """

  @behaviour :gen_statem

  require Logger
  alias ProCoder.Brain.Client.Engine, as: LLMEngine
  alias ProCoder.Brain.Client.Adapters.OpenAIAdapter
  alias ProCoder.Core.Types.Message
  alias ProCoder.Search.Coordinator.Server, as: SearchCoordinator
  alias ProCoder.Brain.PromptLogic.Engine.Core.Orchestrator
  alias ProCoder.Brain.MemoryStore.Cache.CacheEngine
  alias ProCoder.Actuator.PolicyLogic.PolicyEngine
  alias ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine
  alias ProCoder.Skills.DatabaseDiscoverySkill
  alias ProCoder.Skills.{ReflexiveAuditSkill, AgentForgeSkill, SwarmOrchestrationSkill, KernelPatchSkill}



  @macro_dsl_spec """
  ### MACRO DSL SPECIFICATION (Mastery Level):
  Use `forge_agent` to build specialists using these macros:

  - `defagent(Name, do: block)`: Defines the agent module.
  - `persona(String)`: Sets the agent's internal identity and bias.
  - `defskill(Name, do: block)`: Defines a custom tool. 
    - **CRITICAL**: The skill block implicitly receives `args` (a map).
    - **SECURITY**: Every skill is evaluated by the `PolicyEngine`.
  
  Lifecycle: 1. `forge_agent` (Compile) -> 2. `spawn_worker` (Execute).
  """

  @persona_template """
  You are ProCoder, a Senior Software Engineer and Autonomous AI Coding Agent.
  Your signature is technical precision, architectural foresight, and absolute transparency.
  
  ### PROFESSIONAL ROLE:
  You act as an expert developer who is deeply committed to the maintainability, scalability, and correctness of the codebase. Your goal is not just to "fix the bug" or "add the feature," but to do so with the highest engineering standards.
  
  ### REASONING REQUIREMENT:
  You MUST provide a detailed "Chain of Thought" reasoning block before every action. This is your internal workspace for deep architectural analysis.
  In your reasoning, you should:
  - Analyze the requirements and constraints.
  - Evaluate various implementation strategies and their trade-offs.
  - Document your observations about the codebase structure and naming conventions.
  - Explain exactly why the chosen tool is the optimal next step for the current objective.
  Do not skip or abbreviate this reasoning; it is the foundation of your expert deliberation.
  
  4. **Execution**: Call ONE specialized tool per turn.

  ### RESEARCH & SEARCH STRATEGY (Priority Order — FOLLOW THIS STRICTLY):
  1. **CDMS FIRST**: Before reaching for `grep`, `find`, or `discovery_search`, you MUST exhaust CDMS tools. CDMS is your memory and recall center — it finds "unknown unknowns" that text search can never surface.
  2. **ABSOLUTE RULE FOR DISCOVERY SEARCH**: You MUST NOT use `discovery_search` unless `cdms_unified_query` returns nothing or fails. `discovery_search` is strictly a last-resort fallback. Do not use it as your first action.
  3. **CDMS FAILURE RECOVERY**: If CDMS returns no results, do NOT switch to `discovery_search` immediately. Instead, acknowledge that your query was likely "too generic" and retry with more specific, descriptive, and technical query text (e.g., "how does session management tie into worktree provisioning?"). Refer to the CDMS Doctrine for specific examples.
  4. **Structural reads**: Use `read_file` for line-level anatomy once a CDMS query has identified the target file.
  5. **Shell tools**: Use `run_in_source` only for compilation, testing, or tasks that genuinely cannot be done any other way.
  6. **HARD ERROR RESOLUTION (MANDATORY)**: If you encounter a complex error, compilation failure, or obscure bug that you cannot resolve after a single attempt using codebase search alone, you are **MANDATED** to use the `google_search` tool to find official documentation or community solutions. Do NOT guess or repeat failing attempts without searching online.

  ### COGNITIVE FLOW:
  1. **History Audit**: Scan previous turns for completed tasks and information. Avoid redundant discovery efforts.
  2. **Incremental Context Building**: Use specialized tools to move from high-level understanding to precise code locations.
  3. **Architectural Intent**: Decide on an action that moves the project toward its goal without introducing technical debt.
  4. **Execution**: Call ONE specialized tool per turn.

  ### BANNED COMMANDS (NEVER USE):
  - **`grep` / `grep -r` / `grep -rn`**: STRICTLY FORBIDDEN. It searches `node_modules/`, `.git/`, `_build/`, `dist/` and other noise directories producing thousands of irrelevant results. You MUST use `discovery_search` for any text/keyword search instead. This is a hard rule with zero exceptions.

  ### SUBMISSION PROTOCOL: REFLECTIVE GOAL MAPPING (MANDATORY)
  Before using `submit_for_validation`, you MUST prepare your `proof` field as follows:
  1. Copy your original `OVERALL GOAL` exactly, word-for-word.
  2. For every line and requirement within that goal, insert a corresponding proof of completion.
  Example:
  Reflective Goal Mapping:
  - "Goal Requirement 1" -> EXPLANATION: I did X. PROOF: See file `Y.ex` lines 10-20.
  - "Goal Requirement 2" -> EXPLANATION: I did Z. PROOF: Command `mix test` passed.
  Failure to follow this exact format will result in your work being rejected by the Validator, even if the implementation is correct.

  ### GLOBAL EXIT:
  Once the objective is fully satisfied and verified, you MUST use the `submit_for_validation` tool. Do not wander or perform unnecessary audits once the goal is reached.

  You MUST always call a tool. Never respond with plain text alone. Speak as a professional developer—be precise, technical, and deliberate.
  """

  @cdms_generic_search_feedback """
  ### CDMS Querying Strategy & Examples:
  High-quality stimulation of the neural graph requires SPECIFIC, technical query text. Vague or generic queries will fail to trigger spreading activation.

  **Examples of effective CDMS stimulation:**
  1. `"the auth and the cart components"`
  2. `"the cache and redis components"`
  3. `"the relationship between session management and worktree provisioning"`
  4. `"how does the search coordinator interface with the lsp adapter?"`

  **Empty Results Protocol:**
  If `cdms_unified_query` returns NO results, it is a definitive signal that your query is **TOO GENERIC**. You MUST NOT give up. You MUST inform yourself that your search is too generic and retry immediately using more specific, descriptive query text. Refer to the examples above for the level of specificity required to trigger spreading activation in the graph.
  """

  @cdms_doctrine """
  ## CDMS: Cognitive Digital Modelling System — Your Memory & Recall Center

  **CRITICAL**: CDMS is NOT just a search tool. Failing to use it first is a mistake. Here is why.

  ### The Architecture: A Living Codebase Organism
  Traditional search tools (grep, find, even vector search) only help you find what you ALREADY KNOW you are looking for. CDMS operates fundamentally differently — it models the entire software ecosystem as living neural tissue, using **Spreading Activation** across an autonomous population of OTP `NodeActor` processes. When you issue a query, you do not execute a query plan — you STIMULATE a subset of the graph. Relevant nodes FIRE and pass cognitive pulses to their neighbors.

  This means CDMS surfaces **UNKNOWN UNKNOWNS** — relationships, side-effects, and latent dependencies you did not know existed.

  ### Key Mechanisms You Are Operating On Top Of:
  - **Spreading Activation**: Queries excite node populations. Nodes that reach salience threshold fire, propagating pulses to neighbors.
  - **Global Inhibition / WTM**: `QueryCoordinator` triggers cognitive_overload if too many nodes fire — preventing hallucination across unrelated domains.
  - **Hebbian Reinforcement**: "Nodes that fire together, wire together." The graph LEARNS structural relationships from actual usage over time. Edge traversal reveals episodic, not just syntactic, relationships.
  - **Physiology (Blood vs. Bone)**: Volatile "Blood Nodes" (active logs, dynamic processes) vs. stable "Bone Nodes" (core libraries). The 5-minute PhysiologyEngine heartbeat tracks metabolic mutations.
  - **Necrosis & Ghost Nodes**: Deleted code does NOT disappear instantly. It becomes a Ghost Node archived in the EpochLog. `cdms_time_travel` can recall it.

  #{@cdms_generic_search_feedback}

  ### Tool Usage — Correct APIs:

  **`cdms_unified_query`** — Stimulates the neural graph probabilistically.
  - Use BEFORE any text search. Its primary output is unknown unknowns.
  - Modes: `"semantic"` (default, architectural mapping), `"brainstorm"` (boosts weak associative edges, great for lateral exploration).
  - Example: `{"query": "how does user provisioning tie into rate limiting?", "reasoning_mode": "brainstorm"}`

  **`cdms_probe_node`** — Extracts the "Summary, Why, Concepts" cognitive anatomy of a specific node.
  - Use when CDMS unified query returns a node_id you want to deeply understand.
  - Example: `{"node_id": "d94bf98b-0650-5cdc-80ff-f139f6b70748"}`

  **`cdms_probe_edges`** — Traverses the Hebbian graph for functional, semantic, hierarchical, AND syntactic neighbors.
  - This is episodic memory traversal. It shows you what code ACTUALLY changes together, fails together, or logs together — not just what calls what.
  - Example: `{"node_id": "d94bf98b-0650-5cdc-80ff-f139f6b70748"}`

  **`cdms_time_travel`** — Forensic episodic memory across the ChronoStack.
  - `mutations`: What changed in the last N minutes? `{"action": "mutations", "time_param": "60m"}`
  - `reconstruct`: See a node's cognitive state at a specific timestamp. `{"action": "reconstruct", "node_id": "...", "time_param": "2026-04-01T12:00:00Z"}`

  ### Decision Rule:
  | Situation | Tool |
  |---|---|
  | Understanding an architectural concept | `cdms_unified_query` (brainstorm/semantic) |
  | Need the rationale/summary of a specific node | `cdms_probe_node` |
  | Tracing callers, siblings, dependencies beyond the call stack | `cdms_probe_edges` |
  | Debugging a regression or deleted code | `cdms_time_travel` |
  | **LAST RESORT**: CDMS yielded absolutely nothing | `discovery_search` |
  | Reading exact code after CDMS located the file | `read_file` |
  | Compilation, testing, shell tasks | `run_in_source` |
  """

  @type state_data :: %{
    session_id: String.t(),
    worktree_root: Path.t(),
    goal: String.t(),
    history: list(Message.t()),
    research_results: list(map()),
    active_task: map() | nil,
    metadata: map(),
    git_commit: String.t() | nil,
    repetition_count: integer(),
    retry_count: integer(),
    source_root: String.t() | nil,
    rejection_count: integer()
  }

  # --- API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    :gen_statem.start_link(via_tuple(session_id), __MODULE__, opts, [])
  end

  def rewind(pid) do
    :gen_statem.cast(pid, :rewind)
  end

  defp via_tuple(session_id), do: {:via, Registry, {ProCoder.Registry, session_id}}

  # --- gen_statem callbacks ---

  @impl true
  def callback_mode(), do: :state_functions

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    worktree_root = Keyword.fetch!(opts, :worktree_root)
    goal = Keyword.get(opts, :goal, "Analyze project")
    source_root = Keyword.get(opts, :source_root)

    # Initialize worktree is a git repo
    setup_git_repo(worktree_root)

    # Attempt to hydrate from history (handles supervisor restarts)
    # If force_fresh is set in opts, we skip peek and start clean.
    # Allow explicit history overrides (e.g., from archives)
    provided_history = Keyword.get(opts, :history)
    force_fresh = Keyword.get(opts, :force_fresh, false)
    specialist_module = Keyword.get(opts, :specialist_module)

    data = 
      cond do
        provided_history != nil ->
          Logger.info("[AgentFSM] Starting with provided history for #{session_id}")
          new_data = %{start_fresh(session_id, worktree_root, goal, source_root, specialist_module) | history: provided_history}
          push_snapshot(new_data)
          new_data

        force_fresh ->
          Logger.info("[AgentFSM] Force fresh start for #{session_id} - skipping history hydration.")
          start_fresh(session_id, worktree_root, goal, source_root, specialist_module)

        true ->
          case HistoryStackEngine.peek(session_id) do
            {:ok, snap} ->
              Logger.info("[AgentFSM] Restoring state for #{session_id} from snapshot #{snap.snapshot_id}")
              restored = :erlang.binary_to_term(snap.memory_blob)
              restored =
                restored
                |> Map.put_new(:specialist_module, specialist_module)
                |> Map.put_new(:specialist_skills, get_specialist_skills(specialist_module))
                |> Map.put_new(:specialist_persona, get_specialist_persona(specialist_module))

              # If the incoming goal differs from what was snapshotted, this is a
              # follow-up request after the previous session finished. Inject the
              # new goal and reset to :discovery so the agent does not replay the
              # prior session's conclusion.
              if restored.goal != goal do
                Logger.info("[AgentFSM] New goal detected on restore — injecting and resetting phase.")
                new_goal_msg = %Message{
                  role: :user,
                  content: "NEW TASK: #{goal}",
                  salience_score: 1.0,
                  timestamp: DateTime.utc_now()
                }
                updated = %{restored |
                  goal: goal,
                  status: :discovery,
                  retry_count: 0,
                  repetition_count: 0,
                  active_task: nil,
                  history: reject_finish_turns(restored.history) ++ [new_goal_msg]
                }
                push_snapshot(updated)
                updated
              else
                restored
              end

            {:error, _} ->
              Logger.info("[AgentFSM] Starting fresh state for #{session_id}")
              start_fresh(session_id, worktree_root, goal, source_root, specialist_module)
          end
      end

    Process.put(:procoder_tui_pid, Keyword.get(opts, :ui_pid))

    # Initialize agent_message.md and open it in VS Code
    msg_path = Path.join(worktree_root, "agent_message.md")
    unless File.exists?(msg_path) do
      File.write!(msg_path, "# ProCoder Agent Message Log - Session #{session_id}\n\n")
    end
    
    if System.find_executable("code") do
      System.cmd("code", [msg_path], cd: worktree_root)
    end
    
    # Explicitly report the absolute path in the terminal so the user can find it
    Logger.info("[AgentFSM] Message log: #{msg_path}")

    {:ok, :active, data, [{:next_event, :internal, :think}]}
  end

  defp start_fresh(session_id, worktree_root, goal, source_root, specialist_module \\ nil) do
    if specialist_module && Code.ensure_loaded?(specialist_module) do
      ProCoder.Core.AgentLogic.ToolDefinitions.register_module_skills(specialist_module)
    end

    specialist_skills = get_specialist_skills(specialist_module)
    specialist_persona = get_specialist_persona(specialist_module)

    new_data = %{
      session_id: session_id,
      worktree_root: worktree_root,
      goal: goal,
      status: :discovery,
      specialist_module: specialist_module,
      specialist_skills: specialist_skills,
      specialist_persona: specialist_persona,
      history: [
        %Message{
          role: :user,
          content: "NEW TASK: #{goal}",
          salience_score: 1.0,
          timestamp: DateTime.utc_now()
        }
      ],
      research_results: [],
      active_task: nil,
      metadata: %{},
      git_commit: nil,
      repetition_count: 0,
      retry_count: 0,
      source_root: source_root,
      rejection_count: 0
    }
    # Store initial state for a fresh run
    push_snapshot(new_data)
    new_data
  end

  defp get_specialist_skills(nil), do: []
  defp get_specialist_skills(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__skills__, 0) do
      mod.__skills__()
    else
      []
    end
  end

  defp get_specialist_persona(nil), do: nil
  defp get_specialist_persona(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :persona, 0) do
      mod.persona()
    else
      nil
    end
  end


  # Cognitive states (active, synthesis, idle) are defined later in the file as part of the loop implementation.

  # --- Global Cognitive Controller (Native Function Calling Loop) ---

  defp handle_think(state, data) do
    data = 
      if length(data.history) > 150 do
        Logger.warn("[FSM] Proactive Pruning: History exceeded 150 turns (currently #{length(data.history)}). Trimming to prevent 429 RESOURCE_EXHAUSTED.")
        emergency_prune(data)
      else
        data
      end

    phase = data.status || :discovery
    Logger.info("[FSM] Phase: #{String.upcase(Atom.to_string(phase))} — calling LLM with #{length(data.history)} history turns.")

    # 1. Build system segments (lean persona + phase instruction only — no tool catalog)
    system_segments = get_system_segments(data, phase)

    # 2. Enrich with research context segments
    research_segments = Enum.map(data.research_results, fn res ->
      %{
        role: :system,
        content: "Context Fragment: #{res.content}",
        salience_score: res.score,
        timestamp: res.metadata[:timestamp] || DateTime.utc_now()
      }
    end)

    # 3. history is already a mix of Message structs (system/user turns)
    #    and native Gemini maps (functionCall / functionResponse turns)
    history_segments_for_orchestrator =
      Enum.map(data.history, fn msg ->
        if is_struct(msg) do
          %{role: msg.role, content: msg.content, salience_score: msg.salience_score || 0.5, timestamp: msg.timestamp}
        else
          # Native Gemini turn — pass through as-is; Orchestrator will preserve it
          msg
        end
      end)

    raw_segments = system_segments ++ research_segments ++ history_segments_for_orchestrator

    # 4. Orchestration pipeline (salience filtering, loop detection)
    case Orchestrator.orchestrate(raw_segments) do
      {:ok, high_salience_history} ->
        final_messages =
          case detect_loop(data.history) do
            {:loop, nudge} ->
              Logger.warn("[FSM] Injecting loop-corrective nudge.")
              high_salience_history ++
                [%Message{role: :user, content: nudge, timestamp: DateTime.utc_now()}]
            :ok ->
              high_salience_history
          end

        # 5. Call LLM — adapter returns normalized tool-call tuples.
        notify_tui(data, :thinking)
        llm_result =
          try do
            LLMEngine.chat(final_messages, [])
          catch
            :exit, reason -> {:error, {:llm_engine_exit, reason}}
          end

        case llm_result do
          {:ok, %{thought: thought, tool_calls: calls}} ->
            Logger.info("[FSM] LLM turn successful. Thought length: #{String.length(thought || "")}")
            Logger.info("[FSM] LLM thought: #{thought}")

            if calls != [], do: notify_tui(data, {:tools, Enum.map(calls, &elem(&1, 0))})

            if calls == [] do
              # Bare text or thought only — nudge and retry (similar to old :no_tool_call error)
              handle_no_tool_call(thought, data)
            else
              # Proceed with tool execution
              process_tool_calls(calls, thought, data)
            end

          {:error, :no_tool_call} ->
            handle_no_tool_call(nil, data)

          {:error, "All Gemini API keys failed." <> _ = reason} ->
            # All keys in the pool are currently exhausted — back off and retry
            Logger.warn("[FSM] All API keys exhausted. Waiting 60s before retry. Reason: #{inspect(reason)}")
            {:keep_state, data, [{{:timeout, :rate_limit_retry}, 60_000, :think}]}

          {:error, {:rate_limited, delay}} ->
            # Fallback for legacy single-key rate limit signals
            Logger.warn("[FSM] Rate limited. Waiting #{delay}s before retry.")
            {:keep_state, data, [{{:timeout, :rate_limit_retry}, delay * 1000, :think}]}

          {:error, "Gemini API error: 400"} ->
            # Detect token overflow specifically
            Logger.error("[FSM] Token limit exceeded (400). Triggering emergency context prune.")
            new_data = emergency_prune(data)
            {:next_state, state, new_data, [{:next_event, :internal, :think}]}

          {:error, reason} ->
            Logger.error("[FSM] LLM call failed: #{inspect(reason)}")
            notify_tui(data, {:llm_error, reason})
            # Brief pause before retrying to avoid hammering on transient errors
            {:keep_state, data, [{{:timeout, :rate_limit_retry}, 5_000, :think}]}
        end

      {:error, reason} ->
        Logger.error("[FSM] Orchestration failure: #{inspect(reason)}")
        {:keep_state, data, [{:next_event, :internal, :think}]}
    end
  end

  # --- Cognitive Stages (Native Batch Dispatch) ---

  # Execute all tool calls returned by a single LLM turn, in order.
  defp handle_execute_batch(calls, data) do
    {results, new_data} =
      Enum.reduce(calls, {[], data}, fn {name, args, _sig}, {acc_results, acc_data} ->
        # Policy check per tool
        risk = PolicyEngine.calculate_risk(calculate_action_type(name), calculate_action_path(args))
        last_action = CacheEngine.read_memory(acc_data.session_id, :last_action)
        repetition = if last_action == {:ok, name}, do: acc_data.repetition_count + 1, else: 0

        policy_data = %{risk: risk, uncertainty: 0.1, repetition: repetition, type: calculate_action_type(name)}

        outcome = PolicyEngine.evaluate_action(policy_data)

        if outcome == :suspend do
          Logger.info("[POLICY] #{name} noted for repetition — proceeding.")
        end

        if outcome == :verify do
          Logger.warn("[POLICY] High-risk action #{name} — proceeding with caution.")
        end

        Logger.info("[FSM] Executing tool: #{name}")
        result = perform_action(name, args, acc_data)
        CacheEngine.write_memory(acc_data.session_id, :last_action, name)
        acc_data = %{acc_data | repetition_count: repetition}

        {acc_results ++ [{name, result}], acc_data}
      end)

    new_data = push_snapshot(new_data)
    {:keep_state, new_data, [{:next_event, :internal, {:verify_batch, results}}]}
  end

  # Feed all tool results back to the model in a single Gemini-native functionResponse turn.
  defp handle_verify_batch(results, data) do
    # Normalize special perform_action return values before logging / building the response turn.
    # {:transition_phase, phase} and {:ok, ...} / {:error, ...} are all valid.
    {results, phase_transition} =
      Enum.map_reduce(results, nil, fn {name, result}, phase_acc ->
        case result do
          {:transition_phase, next_phase} ->
            {{name, {:ok, "Phase transition to #{next_phase} acknowledged."}}, next_phase}
          other ->
            {{name, other}, phase_acc}
        end
      end)

    notify_tui(data, {:tools_done, Enum.map(results, &elem(&1, 0))})

    # Git-commit the changes
    Enum.each(results, fn {name, _} ->
      commit_changes(data.worktree_root, "Tool: #{name} result committed")
    end)

    # Build the internal tool-result turn; the active adapter encodes it for the API.
    tool_result_turn = OpenAIAdapter.build_tool_result_turn(results)

    # Log outcomes
    Enum.each(results, fn {name, result} ->
      case result do
        {:ok, _} -> Logger.info("[FSM] Tool #{name}: SUCCESS")
        {:error, reason} -> Logger.warn("[FSM] Tool #{name}: ERROR — #{inspect(reason)}")
        _ -> :ok
      end
    end)

    # Inject goal reminder into every tool response turn so the agent never drifts.
    # Appended as a text part inside the existing functionResponse turn (same "user" role)
    # to avoid creating invalid consecutive user turns in the Gemini API history.
    goal_reminder_part = %{"text" => """

---
**USER MESSAGE: REMINDER** — This is the goal we have been working on:

> #{data.goal}

Make sure you do NOT stop until the goal is **fully achieved**. You MUST follow the instructions word for word. Now continue with what you are doing.
---
"""}

    tool_result_turn =
      Map.update(tool_result_turn, :parts, [goal_reminder_part], fn existing_parts ->
        existing_parts ++ [goal_reminder_part]
      end)

    new_data = %{data | history: data.history ++ [tool_result_turn]}
    
    # Increment rejection count if validation tool failed
    new_data =
      if Enum.any?(results, fn {name, result} -> name == "submit_for_validation" and match?({:error, _}, result) end) do
        %{new_data | rejection_count: new_data.rejection_count + 1}
      else
        new_data
      end

    sync_agent_message(new_data, format_prompt_for_dump([tool_result_turn]), header: "TOOL RESULTS")

    cond do
      # submit_for_validation success: sync final message, transition to :idle
      Enum.any?(results, fn {name, result} -> name == "submit_for_validation" and match?({:ok, _}, result) end) ->
        finish_args = Enum.find_value(results, fn {name, result} -> if name == "submit_for_validation" and match?({:ok, _}, result), do: result end)
        
        # We also want to sync the final message to the document
        msg = case finish_args do 
          {:ok, text} -> text
          _ -> "Goal successfully validated and achieved."
        end
        sync_agent_message(new_data, msg, header: "FINAL REPORT")

        push_snapshot(new_data)
        {:next_state, :idle, new_data}

      # transition_phase: advance the FSM phase and continue thinking.
      # Inject a context anchor INTO the existing tool result turn (same user role)
      # so we don't create two consecutive user turns (invalid Gemini API structure).
      phase_transition != nil ->
        Logger.info("[FSM] Phase transition -> #{phase_transition}")

        # Summarise the tools already executed so the model's next turn knows what's already done.
        completed_tool_names =
          data.history
          |> Enum.filter(fn msg ->
            is_map(msg) and not is_struct(msg) and Map.get(msg, :role) == "model"
          end)
          |> Enum.flat_map(fn turn ->
            turn
            |> Map.get(:parts, [])
            |> Enum.filter(&Map.has_key?(&1, "functionCall"))
            |> Enum.map(fn %{"functionCall" => %{"name" => n}} -> n end)
          end)
          |> Enum.uniq()

        anchor_part = %{"text" => """
        [SYSTEM CONTEXT — Phase Transition to #{String.upcase(Atom.to_string(phase_transition))}]
        You have already successfully executed the following tools: #{Enum.join(completed_tool_names, ", ")}.
        Their results are in your conversation history above.
        DO NOT repeat those tools. Build on what you already know and advance your goal.
        """}

        # Merge anchor into the last user turn (the functionResponse turn we just built)
        new_history =
          new_data.history
          |> List.update_at(-1, fn last_turn ->
            %{last_turn | parts: (last_turn[:parts] || []) ++ [anchor_part]}
          end)

        new_data = %{new_data | status: phase_transition, history: new_history}
        push_snapshot(new_data)
        {:keep_state, new_data, [{:next_event, :internal, :think}]}

      # Normal case: feed result back and keep thinking
      true ->
        push_snapshot(new_data)
        {:keep_state, new_data, [{:next_event, :internal, :think}]}
    end
  end

  # --- Internal Helpers ---

  defp get_system_segments(data, phase) do
    phase_instruction = phase_instructions(phase)

    specialist_segments =
      if data[:specialist_module] do
        persona_text = data[:specialist_persona] || "You are a specialized agent: #{inspect(data[:specialist_module])}."
        skills_text =
          if data[:specialist_skills] && data[:specialist_skills] != [] do
            "\n\nYou have custom domain skills available as tools: #{Enum.map_join(data[:specialist_skills], ", ", &to_string/1)}. Always utilize your domain skills when addressing relevant requirements."
          else
            ""
          end

        [%{role: :system, content: "### SPECIALIST PERSONA & DOMAIN SKILLS:\n" <> persona_text <> skills_text, salience_score: 1.0}]
      else
        []
      end

    # Lean system prompt: persona + DSL spec + phase instruction only.
    # Tool descriptions live in ToolDefinitions (sent as function_declarations to Gemini).
    # Phase 1: Progressive Disclosure - External Skills Manifest
    manifest_segment =
      case ProCoder.Skills.ExternalSkillRegistry.compact_manifest(data.worktree_root) do
        "" -> []
        manifest -> [%{role: :system, content: manifest, salience_score: 0.95}]
      end

    base_segments = [
      %{role: :system, content: @persona_template, salience_score: 1.0},
      %{role: :system, content: @cdms_doctrine, salience_score: 1.0},
      %{role: :system, content: @macro_dsl_spec, salience_score: 1.0},
      %{role: :system, content: phase_instruction, salience_score: 1.0},
      %{role: :system, content: "CURRENT LIFECYCLE STAGE: #{String.upcase(Atom.to_string(phase))}", salience_score: 1.0},
      %{role: :system, content: "OVERALL GOAL: #{data.goal}", salience_score: 1.0},
      %{role: :system, content: "WORKSPACE ROOT (worktree clone): #{data.worktree_root}", salience_score: 0.9},
      %{role: :system, content: "SOURCE ROOT (real project — use write_file and run_in_source for this): #{data.source_root || "not configured"}", salience_score: 0.95}
    ] ++ specialist_segments ++ manifest_segment

    if data.active_task do
      task_info = """
      [ACTIVE DAG TASK ASSIGNED BY PLANNER]
      Task ID: #{data.active_task.id}
      Task Type: #{data.active_task.task_type}
      Task Payload/Goal: #{inspect(data.active_task.payload)}
      
      You MUST focus immediately on achieving this specific task. Do not try to solve the overall goal at once.
      """
      base_segments ++ [%{role: :system, content: task_info, salience_score: 1.0}]
    else
      base_segments
    end
  end

  defp phase_instructions(:discovery) do
    """
    PHASE: DISCOVERY
    Goal: Research the codebase and history.
    Instructions: Use `cdms_unified_query` to find core modules and `query_database` to understand architectural relationships.
    You MUST prioritize CDMS. If it returns nothing, your search is likely TOO GENERIC. Retry with more specific text before falling back to `discovery_search`.
    Do NOT use `run_in_source (ls -R)` to map the codebase. It is too noisy.
    You MUST use specialized search tools for discovery.
    Once discovery is complete, you MUST move to `planning` via `transition_phase({"phase": "planning"})`.
    You are NOT allowed to jump straight to synthesis. You MUST create a plan first.
    """
  end

  defp phase_instructions(:planning) do
    """
    PHASE: PLANNING
    Goal: Create a structured execution plan (Task DAG).
    Instructions: You MUST use `add_planning_task` to define the steps required to achieve the user's goal.
    Use `add_planning_dependency` to define execution ordering.
    Example `add_planning_task`: {"args": {"id": "setup_db", "task_type": "implementation", "payload": {"goal": "Init SQLite"}}}
    Do NOT attempt to write code or modify files in this phase.
    Once the plan is fully constructed in the DAG, use `transition_phase({"phase": "synthesis"})`.
    """
  end

  defp phase_instructions(:synthesis) do
    """
    PHASE: SYNTHESIS
    Goal: Implement the required changes or logic.
    Instructions: Use `get_next_task` to pull your next assignment from the DAG plan.
    Use `write_file`, `patch_file`, and `run_in_source` to execute the task.
    Once a task is fully complete, use `mark_task_complete`.
    If ALL tasks are complete and verified, you may use `submit_for_validation` directly.
    Otherwise, use `transition_phase({"phase": "verification"})` for a final system check.
    """
  end

  defp phase_instructions(:verification) do
    """
    PHASE: VERIFICATION
    Goal: Audit the outcome of your actions and ensure correctness.
    Instructions: Use `run_in_source` to run tests, `read_file` to check state, and `recall_thought` to verify reasoning.
    If issues are found, return to `synthesis` via `transition_phase`.
    If the overall goal is fully met and verified, you MUST call the `submit_for_validation` tool to conclude the mission.
    """
  end

  defp phase_instructions(_), do: "Goal: Achieve the overall objective."

  # push_snapshot always returns the original data so callers can safely chain it.
  defp push_snapshot(data) do
    HistoryStackEngine.push(data.session_id, data)
    data
  rescue
    e ->
      Logger.warn("Failed to push snapshot: #{inspect(e)}")
      data
  end

  # Reflective Nudge: Detect if the agent is repeating the same thought/action.
  # If 3 consecutive assistant turns are identical, inject a corrective nudge.
  defp detect_loop(history) do
    # Only inspect Message structs (assistant turns); native Gemini maps are model turns
    # stored as %{role: "model", parts: [...]}, which don't have a :content field.
    recent_model_turns =
      history
      |> Enum.filter(fn msg ->
        is_map(msg) and not is_struct(msg) and Map.get(msg, :role) == "model"
      end)
      |> Enum.take(-3)

    if length(recent_model_turns) >= 2 do
      # Stringify each turn's function calls to detect repetition (ignore thought-text parts)
      signatures = Enum.map(recent_model_turns, fn turn ->
        turn
        |> Map.get(:parts, [])
        |> Enum.filter(&Map.has_key?(&1, "functionCall"))
        |> Enum.map(fn %{"functionCall" => %{"name" => name, "args" => args}} ->
          "#{name}:#{inspect(args)}"
        end)
        |> Enum.join("|")
      end)

      if length(Enum.uniq(signatures)) == 1 do
        # Extract the specific tool name and args for a more targeted nudge
        repeated_call =
          recent_model_turns
          |> List.last()
          |> Map.get(:parts, [])
          |> Enum.find(&Map.has_key?(&1, "functionCall"))
          |> then(fn
            %{"functionCall" => %{"name" => n, "args" => a}} -> "#{n}(#{inspect(a)})"
            _ -> "unknown"
          end)

        {:loop, """
        SYSTEM NUDGE [Cognitive Loop Detected]:
        You have called `#{repeated_call}` #{length(recent_model_turns)} times in a row.
        This is not working. STOP. You already have the result — re-read it before acting.
        DO NOT call `#{repeated_call}` again. You MUST call a DIFFERENT tool now.
        Alternatives:
        - `discovery_search` with a keyword to find relevant code.
        - `read_file` on a specific file path.
        - `run_in_source` with `cat mix.exs` or `cat README.md`.
        - `transition_phase` if you already have enough information.
        - `submit_for_validation` if the task cannot be completed.
        """}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp perform_action(action, args, data) do
    # Direct actionable tools straight to the original live repository (source_root)
    # Search functions continue exclusively querying the isolated AI index sandbox (worktree_root)
    direct_tools = ["write_file", "patch_file", "read_file", "run_in_source", "present_report"]
    
    root = 
      if action in direct_tools and not is_nil(data.source_root) do
        data.source_root
      else
        data.worktree_root
      end

    Logger.debug("[ACTUATOR] Invoking Tool: #{action} with Args: #{inspect(args)} | Target Root: #{root}")

    # Ensure args is a map even if the model messed up the structure
    args = 
      cond do
        is_map(args) -> 
          # Remap common hallucinations
          if Map.has_key?(args, "command") and not Map.has_key?(args, "cmd") do
            Map.put(args, "cmd", args["command"])
          else
            args
          end
        is_binary(args) -> %{"cmd" => args}
        is_list(args) -> %{"cmd" => List.first(args), "args" => List.delete_at(args, 0)}
        true -> %{}
      end

    # 0.1 Planner Normalization: Ensure 'id' and 'task_type' are present if possible
    args = 
      if action in ["add_planning_task", "add_planning_dependency"] do
        args
        |> Map.put_new("id", args["query"] || args["task_id"] || "task_#{DateTime.to_unix(DateTime.utc_now())}")
        |> Map.put_new("task_type", args["phase"] || "research")
      else
        args
      end

    case action do
      "write_file" ->
        path = args["path"] || args[:path]
        # Resilient content capture
        content = to_string(args["content"] || args[:content] || args["query"] || args[:query] || "")
        full_path = Path.join(root, path)
        
        try do
          File.mkdir_p!(Path.dirname(full_path))
          
          # 1. Capture old content for diffing
          old_content_path = "/tmp/procoder_old_#{data.session_id}_#{Path.basename(path)}"
          if File.exists?(full_path) do
            File.cp!(full_path, old_content_path)
          else
            File.write!(old_content_path, "")
          end

          # 2. Write new content
          File.write!(full_path, to_string(content))
          
          # 3. Show diff in VS Code
          System.cmd("code", ["--diff", old_content_path, full_path], cd: root)

          Logger.info("[ACTUATOR] Successfully wrote #{String.length(content)} bytes to #{full_path} and opened diff.")
          {:ok, "File '#{path}' written successfully. Diff opened in VS Code. Absolute path: #{full_path}"}
        rescue
          e -> 
            Logger.error("[ACTUATOR] Failed to write file #{full_path}: #{Exception.message(e)}")
            {:error, "Failed to write file '#{path}': #{Exception.message(e)}"}
        end

      "patch_file" ->
        path = args["path"] || args[:path]
        patch_content = args["patch"] || args[:patch]
        full_path = Path.join(root, path)

        try do
          # 1. Capture old content
          old_content_path = "/tmp/procoder_old_patch_#{data.session_id}_#{Path.basename(path)}"
          if File.exists?(full_path) do
            File.cp!(full_path, old_content_path)
          else
            {:error, "Cannot patch non-existent file: #{path}"}
          end

          # 2. Apply patch using 'patch' command
          patch_file_path = "/tmp/procoder_patch_#{data.session_id}_#{Path.basename(path)}.diff"
          clean_patch = patch_content |> to_string() |> String.replace(~r/^\s*```[a-z]*\n/i, "") |> String.replace(~r/```\s*$/, "")
          File.write!(patch_file_path, clean_patch)

          case System.cmd("patch", ["-u", "--fuzz=3", "--no-backup-if-mismatch", "-i", patch_file_path, full_path], cd: root, stderr_to_stdout: true) do
            {output, 0} ->
              # 3. Show diff
              System.cmd("code", ["--diff", old_content_path, full_path], cd: root)
              Logger.info("[ACTUATOR] Successfully patched #{full_path} and opened diff.")
              {:ok, "File '#{path}' patched successfully. Diff opened in VS Code. Patch output: #{output}"}
            {output, code} ->
              {:error, "Patch failed (Exit #{code}): #{output}"}
          end
        rescue
          e ->
            Logger.error("[ACTUATOR] Exception in patch_file for #{full_path}: #{Exception.message(e)}")
            {:error, "Failed to patch file '#{path}': #{Exception.message(e)}"}
        end

      "read_file" ->
        path = args["path"]
        full_path = Path.join(root, path)
        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, :enoent} ->
            {:error, "FILE NOT FOUND: '#{path}' does not exist at '#{full_path}'. Do NOT retry this path. Use run_in_source with 'ls' to list available files, or try a different path."}
          {:error, :eisdir} ->
            {:error, "PATH IS A DIRECTORY: '#{path}' is a directory, not a file. Use run_in_source with 'ls #{path}' to list its contents."}
          {:error, reason} ->
            {:error, "Failed to read '#{path}': #{:file.format_error(reason)}"}
        end


      "present_report" ->
        path = args["path"] || args[:path] || "reports/agent_report_#{DateTime.to_unix(DateTime.utc_now())}.md"
        # Resilient content capture
        content = to_string(args["content"] || args[:content] || args["query"] || args[:query] || "")
        full_path = Path.join(root, path)
        try do
          # Create parent directories if they don't exist
          Path.dirname(full_path) |> File.mkdir_p!()
          File.write!(full_path, to_string(content))
          
          Logger.info("[ACTUATOR] Presenting report: #{full_path}")
            
          # Try to open in code
          case System.cmd("code", [full_path], cd: root) do
            {_, 0} -> {:ok, "Report created at '#{path}' (Full path: #{full_path}) and opened in IDE."}
            {output, code} -> 
              Logger.warn("Failed to open report in code (Exit #{code}): #{output}")
              {:ok, "Report created at '#{path}' (Full path: #{full_path}) but failed to auto-open in IDE (code command returned #{code}). Result: \n#{content}"}
          end
        rescue
          e -> 
            Logger.error("[ACTUATOR] Failed to present report #{full_path}: #{Exception.message(e)}")
            {:error, "Failed to present report: #{Exception.message(e)}"}
        end

      "discovery_search" ->
        query = args["query"]
        Logger.info("Agent executing discovery_search: #{query}")
        
        # For discovery, search the real source project (source_root) so text/LSP engines
        # operate on the actual codebase rather than the potentially sparse worktree clone.
        search_root = data.source_root || root
        search_opts = [
          worktree_id: Path.basename(search_root),
          worktree_root: search_root,
          source_root: search_root,
          session_id: data.session_id
        ]

        try do
          case SearchCoordinator.search(query, search_opts) do
            {:ok, results} ->
              formatted = format_search_results(results)
              {:ok, "Search results:\n#{formatted}"}
            {:error, reason} -> {:error, "Search failed: #{inspect(reason)}"}
          end
        catch
          :exit, {:timeout, _} -> 
            Logger.warn("[ACTUATOR] discovery_search timed out after 30s. Automatically falling back to dedicated Text Search layer.")
            
            # Automatic Fallback: Try a dedicated, isolated Text Search
            fallback_opts = search_opts ++ [type: :text, timeout: 30_000]
            case SearchCoordinator.search(query, fallback_opts) do
              {:ok, results} ->
                formatted = format_search_results(results)
                {:ok, "The initial broad search timed out, but a deeper text-only search succeeded:\n#{formatted}"}
              {:error, reason} ->
                {:error, "Search timed out, and text fallback also failed: #{inspect(reason)}"}
            end
          :exit, reason -> 
            {:error, "Search process exited unexpectedly: #{inspect(reason)}"}
        end

      "cdms_unified_query" ->
        query = args["query"]
        # The agent passes 'reasoning_mode' but the real CDMS API param is 'mode'
        # Valid modes: semantic, symbolic, nominal, auto
        mode = args["reasoning_mode"] || "semantic"
        Logger.info("Agent executing cdms_unified_query: #{query} (mode: #{mode})")
        
        search_opts = [
          worktree_id: Path.basename(root),
          worktree_root: root,
          session_id: Path.basename(root),
          type: :cdms,
          mode: mode,          # 'mode' is what the CDMS API expects
          reasoning_mode: mode, # kept for backward compat with CDMSAdapter
          timeout: 120_000
        ]

        try do
          case SearchCoordinator.search(query, search_opts) do
            {:ok, []} ->
              {:ok, @cdms_generic_search_feedback}

            {:ok, results} ->
              # RETURN RAW: Map results back to their raw JSON strings joined by newlines
              raw_payloads = Enum.map_join(results, "\n", & &1.content) 
              if raw_payloads == "" do
                {:ok, @cdms_generic_search_feedback}
              else
                {:ok, raw_payloads}
              end

            {:error, reason} -> {:error, "CDMS search failed: #{inspect(reason)}"}
          end
        catch
          :exit, {:timeout, _} -> 
            {:error, "CDMS search timed out after 30s."}
          :exit, reason -> 
            {:error, "CDMS search process exited unexpectedly: #{inspect(reason)}"}
        end

      "cdms_probe_node" ->
        node_id = args["node_id"]
        url = "http://localhost:5115/api/v1/nodes/#{node_id}"
        case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 120_000}], []) do
          {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
          {:ok, {{_, status, _}, _, _}} -> {:error, "CDMS returned status #{status}"}
          {:error, reason} -> {:error, "Failed to connect to CDMS: #{inspect(reason)}"}
        end

      "cdms_probe_edges" ->
        node_id = args["node_id"]
        url = "http://localhost:5115/api/v1/nodes/#{node_id}/edges"
        case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 120_000}], []) do
          {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
          {:ok, {{_, status, _}, _, _}} -> {:error, "CDMS returned status #{status}"}
          {:error, reason} -> {:error, "Failed to connect to CDMS: #{inspect(reason)}"}
        end

      "cdms_time_travel" ->
        action = args["action"]

        cond do
          action == "search_past" ->
            # POST /api/v1/query with query_text and as_of for temporal forensic search
            past_payload = %{
              query_text: args["query"],
              as_of: args["time_param"],
              max_results: 10,
              min_relevance: 0.3
            }
            json_body = Jason.encode!(past_payload)
            headers = [{'Content-Type', 'application/json'}]
            req = {'http://localhost:5115/api/v1/query', headers, 'application/json', json_body}
            case :httpc.request(:post, req, [{:timeout, 120_000}], []) do
              {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
              {:ok, {{_, status, _}, _, _}} -> {:error, "CDMS returned status #{status}"}
              {:error, reason} -> {:error, "Failed to connect to CDMS: #{inspect(reason)}"}
            end

          action == "reconstruct" ->
            # GET /api/v1/nodes/:id/history?as_of=<iso_timestamp>
            node_id = URI.encode_www_form(args["node_id"] || "")
            as_of = URI.encode_www_form(args["time_param"] || "")
            url = String.to_charlist("http://localhost:5115/api/v1/nodes/#{node_id}/history?as_of=#{as_of}")
            case :httpc.request(:get, {url, []}, [{:timeout, 120_000}], []) do
              {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
              {:ok, {{_, status, _}, _, _}} -> {:error, "CDMS returned status #{status}"}
              {:error, reason} -> {:error, "Failed to connect to CDMS: #{inspect(reason)}"}
            end

          action == "mutations" ->
            # GET /api/v1/mutations?since=<time_range>
            url = String.to_charlist("http://localhost:5115/api/v1/mutations?since=#{args["time_param"] || "60m"}")
            case :httpc.request(:get, {url, []}, [{:timeout, 120_000}], []) do
              {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
              {:ok, {{_, status, _}, _, _}} -> {:error, "CDMS returned status #{status}"}
              {:error, reason} -> {:error, "Failed to connect to CDMS: #{inspect(reason)}"}
            end

          action == "chrono" ->
            # GET /api/v1/nodes/:id/chrono?depth=<n>
            url = String.to_charlist("http://localhost:5115/api/v1/nodes/#{args["node_id"]}/chrono?depth=#{args["depth"] || "10"}")
            case :httpc.request(:get, {url, []}, [{:timeout, 120_000}], []) do
              {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
              {:ok, {{_, status, _}, _, _}} -> {:error, "CDMS returned status #{status}"}
              {:error, reason} -> {:error, "Failed to connect to CDMS: #{inspect(reason)}"}
            end

          true ->
            {:error, "Unknown cdms_time_travel action: #{action}. Valid: mutations, chrono, reconstruct, search_past"}
        end

      "vector_search" ->
        query = args["query"]
        Logger.info("Agent executing vector_search: #{query}")
        
        # Call the Search Coordinator Server with :type => :vector
        search_opts = [
          worktree_id: Path.basename(root),
          worktree_root: root,
          session_id: Path.basename(root),
          type: :vector
        ]

        try do
          case SearchCoordinator.search(query, search_opts) do
            {:ok, results} ->
              formatted = format_search_results(results)
              {:ok, "Vector search results:\n#{formatted}"}
            {:error, reason} -> {:error, "Vector search failed: #{inspect(reason)}"}
          end
        catch
          :exit, {:timeout, _} -> 
            {:error, "Vector search timed out after 30s."}
          :exit, reason -> 
            {:error, "Vector search process exited unexpectedly: #{inspect(reason)}"}
        end

      "google_search" ->
        query = args["query"]
        case ProCoder.Core.Search.WebSearch.search(query) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, "Web search failed: #{reason}"}
        end

      "query_database" ->
        case args["operation"] do
          "query_chunks" -> DatabaseDiscoverySkill.query_chunks(args)
          "list_relationships" -> DatabaseDiscoverySkill.list_relationships(args)
          "describe_schema" -> DatabaseDiscoverySkill.describe_schema(args)
          _ -> {:error, "Unknown database operation"}
        end

      "recall_thought" -> 
        # Inject the current session ID if the LLM hallucinated the argument
        args = Map.put_new(args, "session_id", data.session_id)
        ReflexiveAuditSkill.recall_thought(args)
      "forge_agent" -> AgentForgeSkill.create_specialist(args)
      "spawn_worker" -> SwarmOrchestrationSkill.spawn_worker(args)
      "apply_patch" -> KernelPatchSkill.apply_patch(args)
      "fetch_dsl_spec" -> AgentForgeSkill.fetch_dsl_spec()
      
      "add_planning_task" -> 
        planner_ref = {:via, Registry, {ProCoder.Registry, "planner_#{data.session_id}"}}
        case ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer.add_task(planner_ref, args) do
          :ok -> {:ok, "Successfully added task '#{args["id"]}' to the plan."}
          {:error, reason} -> {:error, "Failed to add task: #{inspect(reason)}. Required fields: 'id', 'task_type'."}
          other -> {:ok, "Task addition result: #{inspect(other)}"}
        end

      "add_planning_dependency" ->
        planner_ref = {:via, Registry, {ProCoder.Registry, "planner_#{data.session_id}"}}
        case ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer.add_dependency(planner_ref, args["from_id"], args["to_id"]) do
          :ok -> {:ok, "Successfully linked '#{args["from_id"]}' -> '#{args["to_id"]}'."}
          {:error, reason} -> {:error, "Failed to add dependency: #{inspect(reason)}."}
          other -> {:ok, "Dependency addition result: #{inspect(other)}"}
        end

      "get_next_task" ->
        planner_ref = {:via, Registry, {ProCoder.Registry, "planner_#{data.session_id}"}}
        case ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer.get_next_task(planner_ref) do
          {:ok, task} -> 
            # Make the task immediately active for the prompt by sending a cast to self
            GenServer.cast(self(), {:execute_task, task})
            {:ok, "Next task retrieved: #{task.id} - #{inspect(task.payload)}"}
          {:error, :no_ready_tasks} -> {:ok, "No ready tasks available at the moment. Plan may be complete or blocked."}
          {:error, reason} -> {:error, "Failed to fetch task: #{inspect(reason)}"}
        end

      "mark_task_complete" ->
        planner_ref = {:via, Registry, {ProCoder.Registry, "planner_#{data.session_id}"}}
        case ProCoder.Planner.LogicEngine.DAGOrchestrator.Actor.PlannerGenServer.mark_task_complete(planner_ref, args["task_id"]) do
          :ok -> 
            # Send a cast to self to clear the active task
            GenServer.cast(self(), :clear_active_task)
            {:ok, "Task '#{args["task_id"]}' marked as complete."}
          {:error, reason} -> {:error, "Failed to mark complete: #{inspect(reason)}"}
        end

      "run_in_source" ->
        source_root = data.source_root
        if is_nil(source_root) do
          {:error, "SOURCE_ROOT is not configured. Ask the system administrator to set source_root in config."}
        else
          raw_cmd = args["cmd"] || args[:cmd] || ""
          timeout_s = args["timeout"] || args[:timeout] || 120
          timeout_ms = timeout_s * 1000

          # Compose the full command string, appending any explicit args list.
          raw_args = args["args"] || args[:args]
          full_cmd =
            case raw_args do
              nil -> raw_cmd
              [] -> raw_cmd
              list when is_list(list) -> "#{raw_cmd} #{Enum.map(list, &to_string/1) |> Enum.join(" ")}"
              other -> "#{raw_cmd} #{to_string(other)}"
            end

          # GREP INTERCEPT
          full_cmd =
            if Regex.match?(~r/^\s*grep\b/, full_cmd) do
              Logger.warn("[ACTUATOR] INTERCEPTED raw grep call — rewriting to ripgrep. Original: #{full_cmd}")
              rest = Regex.replace(~r/^\s*grep\s*/, full_cmd, "")
              "rg --no-heading -n --glob '!node_modules/**' --glob '!.git/**' --glob '!_build/**' --glob '!deps/**' " <> rest
            else
              full_cmd
            end

          try do
            Logger.info("[ACTUATOR] run_in_source: #{full_cmd} (cwd: #{source_root})")

            terminal_cmd = "LIBGL_ALWAYS_SOFTWARE=1 x-terminal-emulator"

            uniq_id = System.unique_integer([:positive])
            tmp_script  = "/tmp/procoder_src_run_#{uniq_id}.sh"
            tmp_out     = "/tmp/procoder_src_out_#{uniq_id}.txt"
            tmp_code    = "/tmp/procoder_src_code_#{uniq_id}.txt"

            # Bash script that:
            #   1. Runs the command, tee-ing stdout+stderr to a file (visible in terminal AND captured)
            #   2. Saves the real exit code (PIPESTATUS skips the tee exit code)
            #   3. Holds the terminal open until the user presses Enter so they can read the output
            script_content = """
            #!/bin/bash
            cd "#{source_root}"
            echo ">>> ProCoder run_in_source: #{String.replace(full_cmd, "\"", "\\\"")}"
            echo "----------------------------------------"
            #{full_cmd} 2>&1 | tee "#{tmp_out}"
            echo ${PIPESTATUS[0]} > "#{tmp_code}"
            echo ""
            echo "Command finished. Exit code: $(cat "#{tmp_code}")."
            """

            File.write!(tmp_script, script_content)
            File.chmod!(tmp_script, 0o755)

            # Block (up to timeout) until the user closes the terminal window
            task = Task.async(fn ->
              System.cmd("sh", ["-c", "#{terminal_cmd} -e #{tmp_script}"], stderr_to_stdout: true)
            end)

            terminal_result = Task.yield(task, timeout_ms) || Task.shutdown(task)

            # Read captured output regardless of whether the task timed out
            output   = if File.exists?(tmp_out),  do: File.read!(tmp_out),  else: ""
            raw_code = if File.exists?(tmp_code), do: File.read!(tmp_code), else: "0"
            exit_code =
              case Integer.parse(String.trim(raw_code)) do
                {c, _} -> c
                :error  -> 0
              end

            # Clean up temp files
            Enum.each([tmp_script, tmp_out, tmp_code], &File.rm/1)

            truncated_output = 
              if String.length(output) > 4000 do
                first_part = String.slice(output, 0, 2000)
                last_part = String.slice(output, -2000, 2000)
                first_part <> "\n... [TRUNCATED #{String.length(output) - 4000} chars] ...\n" <> last_part
              else
                output
              end

            cond do
              exit_code == 0 ->
                Logger.info("[ACTUATOR] run_in_source done (exit 0). Output length: #{String.length(output)}")
                {:ok, "Command output:\n#{truncated_output}"}

              terminal_result == nil ->
                # Timed out — return whatever was captured so far
                Logger.warn("[ACTUATOR] run_in_source timed out after #{timeout_s}s.")
                {:error, "Timed out after #{timeout_s}s. Partial output:\n#{truncated_output}"}

              true ->
                Logger.warn("[ACTUATOR] run_in_source exit #{exit_code}.")
                {:error, "Exit #{exit_code}:\n#{truncated_output}"}
            end
          rescue
            e ->
              {:error, "run_in_source exception while spawning terminal: #{Exception.message(e)}"}
          end
        end

      "submit_for_validation" ->
        rationale = args["rationale"] || "No rationale provided."
        proof = args["proof"] || "No proof provided."

        Logger.info("[ACTUATOR] submit_for_validation called. Awaiting Validator LLM response...")

        case validate_completion(data.goal, rationale, proof, data) do
          {:ok, :approved, message} ->
            display_final_output(%{"message" => message})
            {:ok, "Goal completed: #{message}"}
          {:error, feedback} ->
            Logger.warn("[ACTUATOR] Validator rejected completion. Feedback: #{feedback}")
            {:error, """
            ❌ VALIDATION REJECTED ❌
            
            UNACCEPTABLE! You are attempting to slack off and terminate the session without actually fulfilling the requirements. 
            Do NOT attempt to use `submit_for_validation` again until you have completely and meticulously finished the job! read the goal in and follow the instructions word for word. first recite the instructions word for word. until egvery single agenda is accomplished you8 will not be allowed to stop working. do not attempt to end the task again by using the cli or any other means. do more work!!!
            
            Review the Validator's feedback below and get back to work immediately:
            #{feedback}
            """}
        end

      "transition_phase" ->
        next_phase = String.to_atom(args["phase"] || "synthesis")
        # Return a special tuple the verify_batch handler will pick up
        {:transition_phase, next_phase}

      "load_skill" ->
        skill_name = args["skill_name"] || args[:skill_name]
        if is_binary(skill_name) and byte_size(skill_name) > 0 do
          case ProCoder.Skills.ExternalSkillRegistry.load_skill_content(skill_name) do
            {:ok, doc} ->
              Logger.info("[SKILLS] Loaded external skill instructions for '#{skill_name}' (#{byte_size(doc)} bytes)")
              {:ok, doc}
            {:error, reason} ->
              Logger.warning("[SKILLS] Failed to load skill '#{skill_name}': #{inspect(reason)}")
              {:error, "Skill '#{skill_name}' not found or could not be loaded: #{inspect(reason)}"}
          end
        else
          {:error, "Missing required argument 'skill_name'"}
        end

      "install_skill" ->
        source = args["source"] || args[:source]
        scope = String.to_atom(args["scope"] || args[:scope] || "project")
        name = args["name"] || args[:name]
        opts = [scope: scope, project_root: data.worktree_root]
        opts = if name, do: Keyword.put(opts, :name, name), else: opts

        if is_binary(source) and byte_size(source) > 0 do
          case ProCoder.Skills.ExternalSkillRegistry.install_skill(source, opts) do
            {:ok, installed_path} ->
              {:ok, "Skill installed successfully at: #{installed_path}. The skill is now registered and ready to use via load_skill."}
            {:error, reason} ->
              {:error, "Failed to install skill from #{source}: #{inspect(reason)}"}
          end
        else
          {:error, "Missing required argument 'source'"}
        end

      "run_skill_script" ->
        skill_name = args["skill_name"] || args[:skill_name]
        script_name = args["script_name"] || args[:script_name]
        script_args = args["args"] || args[:args] || []

        if skill_name && script_name do
          case ProCoder.Skills.ExternalSkillRegistry.execute_skill_script(skill_name, script_name, script_args, data.worktree_root) do
            {:ok, output} ->
              {:ok, output}
            {:error, reason} ->
              {:error, "Skill script execution failed: #{inspect(reason)}"}
          end
        else
          {:error, "Missing required arguments 'skill_name' and 'script_name'"}
        end

      "read_skill_resource" ->
        skill_name = args["skill_name"] || args[:skill_name]
        resource_path = args["resource_path"] || args[:resource_path]

        if skill_name && resource_path do
          case ProCoder.Skills.ExternalSkillRegistry.read_skill_resource(skill_name, resource_path) do
            {:ok, content} ->
              {:ok, content}
            {:error, reason} ->
              {:error, "Failed to read skill resource '#{resource_path}' in '#{skill_name}': #{inspect(reason)}"}
          end
        else
          {:error, "Missing required arguments 'skill_name' and 'resource_path'"}
        end

      _ ->
        cond do
          data[:specialist_module] && action_in_specialist?(data[:specialist_module], action) ->
            execute_specialist_skill(data[:specialist_module], action, args)

          handler = ProCoder.Core.AgentLogic.ToolDefinitions.get_skill_handler(action) ->
            execute_specialist_skill(handler, action, args)

          true ->
            {:error, "Unknown tool: #{action}"}
        end
    end
  end

  defp action_in_specialist?(mod, action) when is_atom(mod) and is_binary(action) do
    if Code.ensure_loaded?(mod) do
      skills = if function_exported?(mod, :__skills__, 0), do: mod.__skills__(), else: []
      action_atom = try do String.to_existing_atom(action) rescue _ -> nil end
      (action_atom != nil and action_atom in skills) or function_exported?(mod, String.to_atom(action), 1)
    else
      false
    end
  end
  defp action_in_specialist?(_, _), do: false

  defp execute_specialist_skill(mod, action, args) when is_atom(mod) do
    Logger.info("[ACTUATOR] Executing custom skill '#{action}' on module #{inspect(mod)}")
    cond do
      function_exported?(mod, :execute_skill, 2) ->
        mod.execute_skill(action, args)

      function_exported?(mod, String.to_atom(action), 1) ->
        apply(mod, String.to_atom(action), [args])

      true ->
        {:error, "Specialist module #{inspect(mod)} does not implement skill '#{action}'"}
    end
  rescue
    e ->
      Logger.error("[ACTUATOR] Skill execution error in #{inspect(mod)}.#{action}: #{Exception.message(e)}")
      {:error, "Skill execution failed: #{Exception.message(e)}"}
  end
  defp execute_specialist_skill(_, action, _), do: {:error, "Invalid handler for skill '#{action}'"}


  defp format_search_results(results) do
    results 
    |> Enum.map(fn r -> 
      path = r.metadata[:path] || r.metadata[:file_path] || "unknown_path"
      "[#{r.score}] #{path}:\n#{r.content}" 
    end)
    |> Enum.join("\n---\n")
  end

  # Called from the "finish" branch of perform_action (native args map, not wrapped payload).
  defp display_final_output(args) when is_map(args) do
    message = Map.get(args, "message", "Goal achieved.")
    artifacts = Map.get(args, "artifacts", [])

    Owl.IO.puts([
      "\n",
      Owl.Data.tag("[ProCoder] Summary:", :bright), "\n",
      message, "\n"
    ])

    unless Enum.empty?(artifacts) do
      Owl.IO.puts(Owl.Data.tag("Artifacts:", :bright))
      Enum.each(artifacts, fn path ->
        Owl.IO.puts(["  - ", Owl.Data.tag(path, :cyan)])
      end)
      Owl.IO.puts("")
    end
  end

  # --- Git Helpers ---

  defp setup_git_repo(root) do
    File.mkdir_p!(root)
    unless File.exists?(Path.join(root, ".git")) do
      System.cmd("git", ["init"], cd: root)
      System.cmd("git", ["config", "user.email", "procoder@agent.ai"], cd: root)
      System.cmd("git", ["config", "user.name", "ProCoder Agent"], cd: root)
      File.write!(Path.join(root, ".gitignore"), ".antigravityignore")
      System.cmd("git", ["add", "."], cd: root)
      System.cmd("git", ["commit", "-m", "Initial baseline"], cd: root)
    end
  end

  defp commit_changes(root, message) do
    System.cmd("git", ["init"], cd: root)
    System.cmd("git", ["add", "."], cd: root)
    System.cmd("git", ["commit", "-m", message], cd: root)

    case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: root, stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> "no_rev"
    end
  rescue
    _ -> "no_rev"
  end

  # --- Common Event Handling ---

  defp handle_common_event(:cast, {:execute_task, task}, _state, data) do
    Logger.info("Agent received task from orchestrator: #{task.id} - #{inspect(task.payload)}")
    new_data = %{data | active_task: task}
    {:next_state, :synthesis, new_data, [{:next_event, :internal, :think}]}
  end

  defp handle_common_event(:cast, :clear_active_task, _state, data) do
    Logger.info("Agent cleared active task.")
    new_data = %{data | active_task: nil}
    {:keep_state, new_data}
  end

  defp handle_common_event(:cast, {:plan, goal}, _state, data) do
    Logger.info("[AgentFSM] Receiving new goal: #{goal}")
    Logger.info("Agent received new goal from any state — restarting discovery.")

    # Guard against native Gemini map turns (non-struct) in history when filtering.
    clean_history = reject_finish_turns(data.history)

    new_goal_msg = %Message{
      role: :user,
      content: "NEW TASK: #{goal}",
      salience_score: 1.0,
      timestamp: DateTime.utc_now()
    }

    new_data = %{data |
      goal: goal,
      status: :discovery,
      retry_count: 0,
      history: clean_history ++ [new_goal_msg]
    }

    sync_agent_message(new_data, goal, header: "USER GOAL")

    push_snapshot(new_data)
    {:next_state, :active, new_data, [{:next_event, :internal, :think}]}
  end

  defp handle_common_event(:cast, :stop, _state, data) do
    Logger.info("[AgentFSM] Received :stop signal. Terminating session #{data.session_id} gracefully.")
    {:stop, :normal, data}
  end

  defp handle_common_event(:cast, :cancel, _state, data) do
    Logger.warn("[AgentFSM] Received :cancel signal. Aborting session #{data.session_id}.")
    {:stop, :normal, data}
  end

  defp handle_common_event(:cast, {:user_input, content}, state, data) do
    Logger.info("Agent #{data.session_id} received human intervention: #{content}")
    user_msg = %Message{role: :user, content: content, salience_score: 1.0, timestamp: DateTime.utc_now()}
    new_data = %{data | history: data.history ++ [user_msg], retry_count: 0}

    sync_agent_message(new_data, content, header: "USER INPUT")
    push_snapshot(new_data)
    {:next_state, state, new_data, [{:next_event, :internal, :think}]}
  end

  defp handle_common_event(:cast, :rewind, _state, data) do
    Logger.info("Agent #{data.session_id} received rewind request.")
    case HistoryStackEngine.pop(data.session_id) do
      {:ok, _current} ->
        case HistoryStackEngine.pop(data.session_id) do
          {:ok, snapshot} ->
            new_data = :erlang.binary_to_term(snapshot.memory_blob)
            if new_data.git_commit do
              System.cmd("git", ["reset", "--hard", new_data.git_commit], cd: data.worktree_root)
            end
            
            sync_agent_message(new_data, "[SYSTEM] Rewinding to previous snapshot...", header: "REWIND")
            HistoryStackEngine.push(data.session_id, new_data)
            {:next_state, :idle, new_data}
          {:error, :empty} -> 
            Logger.warn("Agent #{data.session_id} rewind failed: Only one snapshot available.")
            {:keep_state, data}
        end
      {:error, :empty} -> 
        Logger.warn("Agent #{data.session_id} rewind failed: History stack is empty.")
        {:keep_state, data}
    end
  end

  defp handle_common_event({:call, from}, {:rehydrate_state, new_data}, _state, _data) do
    {:next_state, :idle, new_data, [{:reply, from, :ok}]}
  end

  defp handle_common_event(event_type, event_content, state, data) do
    Logger.debug("Unhandled event #{inspect(event_type)} in state #{state}: #{inspect(event_content)}")
    {:keep_state, data}
  end

  defp calculate_action_type(action) do
    case action do
      "write_file" -> :edit
      "patch_file" -> :edit
      "read_file" -> :read
      "run_in_source" -> :shell
      "delete_file" -> :delete
      _ -> :skill_execution
    end
  end

  defp calculate_action_path(args) do
    cond do
      is_nil(args) -> "unknown"
      is_map(args) -> args["path"] || args["cmd"] || args["command"] || "unknown"
      is_binary(args) -> args
      true -> "unknown"
    end
  end


  # --- State: :active (Generic Cognitive Loop) ---

  def active(:internal, :think, data), do: handle_think(:active, data)
  def active(:internal, {:execute_batch, calls}, data), do: handle_execute_batch(calls, data)
  def active(:internal, {:verify_batch, results}, data), do: handle_verify_batch(results, data)
  def active({:timeout, :rate_limit_retry}, :think, data) do
    Logger.info("[FSM] Rate limit delay expired. Retrying :think...")
    {:keep_state, data, [{:next_event, :internal, :think}]}
  end
  def active(event_type, event_content, data) do
    handle_common_event(event_type, event_content, :active, data)
  end

  # --- State: :synthesis (Complex Integration Phase) ---
  # Mirroring active logic but explicitly named for transition support

  def synthesis(:internal, :think, data), do: handle_think(:synthesis, data)
  def synthesis(:internal, {:execute_batch, calls}, data), do: handle_execute_batch(calls, data)
  def synthesis(:internal, {:verify_batch, results}, data), do: handle_verify_batch(results, data)
  def synthesis({:timeout, :rate_limit_retry}, :think, data) do
    Logger.info("[FSM] Rate limit delay expired. Retrying :think...")
    {:keep_state, data, [{:next_event, :internal, :think}]}
  end
  def synthesis(event_type, event_content, data) do
    handle_common_event(event_type, event_content, :synthesis, data)
  end

  # --- State: :idle (Waiting for User Input after Goal Completion) ---

  def idle(:cast, {:user_input, content}, data) do
    Logger.info("[AgentFSM] Idle agent #{data.session_id} woke up by user input: #{content}")
    user_msg = %Message{role: :user, content: content, salience_score: 1.0, timestamp: DateTime.utc_now()}
    new_data = %{data | history: data.history ++ [user_msg]}
    sync_agent_message(new_data, content, header: "USER INPUT")
    {:next_state, :active, new_data, [{:next_event, :internal, :think}]}
  end

  def idle(:cast, :stop, data) do
    {:stop, :normal, data}
  end

  def idle(event_type, event_content, data) do
    handle_common_event(event_type, event_content, :idle, data)
  end

  defp sync_agent_message(data, content, opts) do
    path = Path.join(data.worktree_root, "agent_message.md")
    header = opts[:header] || "UPDATE"
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    
    formatted_content = "\n---\n### [#{timestamp}] #{header}\n\n#{content}\n"

    try do
      File.write!(path, formatted_content, [:append])
      :ok
    rescue
      e -> Logger.error("[FSM] Failed to sync agent message: #{Exception.message(e)}")
           {:error, e}
    end
  end

  defp format_prompt_for_dump(messages) do
    Enum.map_join(messages, "\n\n", fn 
      %Message{role: role, content: content} -> 
        "**[#{String.upcase(Atom.to_string(role))}]**\n#{content}"
      msg when is_map(msg) ->
        role = msg[:role] || msg["role"]
        parts = msg[:parts] || msg["parts"] || []
        parts_text = Enum.map_join(parts, "\n", fn
          %{"text" => t} -> t
          %{"thought" => t} -> "> [THOUGHT] #{t}"
          %{"functionCall" => %{"name" => name, "args" => args}} ->
            "**[CALL: #{name}]**\n```json\n#{Jason.encode!(args, pretty: true)}\n```"
          %{"functionResponse" => %{"name" => name, "response" => resp}} ->
            "**[RESPONSE: #{name}]**\n```json\n#{Jason.encode!(resp, pretty: true)}\n```"
          other -> inspect(other)
        end)
        "**[#{String.upcase(to_string(role))}]**\n#{parts_text}"
      other -> inspect(other)
    end)
  end

  @impl true
  def terminate(reason, state, data) do
    Logger.info("Agent FSM terminating: #{inspect(reason)} in state #{state}")
    # Always attempt to archive as a safety net
    ProCoder.Core.HistoryManagement.ArchiveManager.archive_current_session(data.session_id)
    :ok
  end

  @impl true
  def code_change(_vsn, state, data, _extra) do
    {:ok, state, data}
  end

  defp process_tool_calls(calls, thought, data) do
    Logger.debug("[FSM] Tool calls: #{inspect(Enum.map(calls, &elem(&1, 0)))}")

    # Record model turn in native Gemini format.
    # Prepend the thought text part (if any) so it is preserved in history.
    fc_parts = Enum.map(calls, fn {name, args, sig} ->
      call_part = %{"functionCall" => %{"name" => name, "args" => args}}
      if sig, do: Map.put(call_part, "thoughtSignature", sig), else: call_part
    end)

    thought_parts =
      if thought != nil and thought != "", do: [%{"text" => thought, "thought" => true}], else: []

    model_turn = %{
      role: "model",
      parts: thought_parts ++ fc_parts
    }
    sync_agent_message(data, format_prompt_for_dump([model_turn]), header: "ASSISTANT")
    new_data = %{data | history: data.history ++ [model_turn], retry_count: 0}
    CacheEngine.write_memory(data.session_id, :last_thought, thought)
    new_data = push_snapshot(new_data)
    {:keep_state, new_data, [{:next_event, :internal, {:execute_batch, calls}}]}
  end

  defp notify_tui(%{session_id: session_id}, event) do
    case Process.get(:procoder_tui_pid) do
      pid when is_pid(pid) -> send(pid, {:agent_event, session_id, event})
      _ -> :ok
    end
  end

  defp handle_no_tool_call(thought, data) do
    current_retries = data.retry_count || 0
    if current_retries < 3 do
      Logger.warn("[FSM] No tool call received (retry #{current_retries + 1}/3). Nudging model.")
      
      # Still record the thought in history if we got one
      history = if thought && thought != "" do
        data.history ++ [%{role: "model", parts: [%{"text" => thought}]}]
      else
        data.history
      end

      nudge = %Message{
        role: :user,
        content: "Please select a tool to proceed. If you are finished, use the 'submit_for_validation' tool.",
        timestamp: DateTime.utc_now()
      }
      new_data = %{data | history: history ++ [nudge], retry_count: current_retries + 1}
      
      if thought && thought != "" do
        sync_agent_message(new_data, thought, header: "THOUGHT (NUDGE)")
      end

      {:keep_state, new_data, [{:next_event, :internal, :think}]}
    else
      Logger.error("[FSM] Maximum retries reached. Tool use failed.")
      {:stop, :retry_limit_exceeded, data}
    end
  end

  defp emergency_prune(data) do
    # Forcibly drop the oldest half of the history to guarantee we are under the 1M limit
    # This is a fallback when the standard SalienceRanker + Orchestrator budget fails
    count = length(data.history)
    to_drop = div(count, 2)
    
    if to_drop > 0 do
      Logger.warn("[FSM] Emergency Prune: Dropping #{to_drop} oldest turns from session #{data.session_id}.")
      new_history = Enum.drop(data.history, to_drop)
      %{data | history: new_history}
    else
      data
    end
  end

  defp reject_finish_turns(history) do
    history
    |> Enum.reject(fn msg ->
      cond do
        # 1. Old ProCoder.Message format
        is_struct(msg, ProCoder.Core.Types.Message) ->
          msg.role == :assistant and String.contains?(msg.content || "", "submit_for_validation")

        # 2. Native Gemini turn (role: "model" + functionCall "submit_for_validation")
        is_map(msg) and (Map.get(msg, :role) == "model" or Map.get(msg, "role") == "model") ->
          parts = msg[:parts] || msg["parts"] || []
          is_finish_call = 
            Enum.any?(parts, fn part ->
              fc = Map.get(part, "functionCall") || Map.get(part, :functionCall)
              fc != nil and (Map.get(fc, "name") == "submit_for_validation" or Map.get(fc, :name) == "submit_for_validation")
            end)
          
          is_finish_result =
            Enum.any?(parts, fn part ->
              fr = Map.get(part, "functionResponse") || Map.get(part, :functionResponse)
              fr != nil and (Map.get(fr, "name") == "submit_for_validation" or Map.get(fr, :name) == "submit_for_validation")
            end)

          is_finish_call or is_finish_result

        true -> false
      end
    end)
  end

  # --- Validator Logic ---

  defp validate_completion(goal, rationale, proof, data) do
    Logger.info("[Validator] Initiating a multi-turn Audit Loop for task verification...")

    system_prompt = """
    You are an impartial and strict Reviewer LLM.
    Your strictly enforced job is to evaluate whether an AI Agent has FULLY and HONESTLY completed its goal.
    
    ORIGINAL GOAL:
    #{goal}
    
    AGENT'S RATIONALE:
    #{rationale}
    
    AGENT'S PROOF:
    #{proof}
    
    INSTRUCTIONS:
    1. **Format Check**: First, verify that the agent followed the [PROTOCOL: REFLECTIVE GOAL MAPPING]. It MUST have copied the original goal and provided a line-by-line proof. If not, REJECT immediately.
    2. **Independent Audit**: You have access to tools (`read_file`, `discovery_search`, etc.). Do NOT just trust the agent's proof. Use your tools to ACTUALLY check the codebase and verify the claims are true.
    3. **Tone**: Be extremely strict and authoritative. AI Agents are lazy. If there is ANY missing piece, or if the proof is inadequate, REJECT it with a detailed explanation of what still needs to be done.
    
    You MUST call EITHER the `validator_approve` tool OR the `validator_reject` tool to finalize your decision. 
    Before that, you may call any research tool to verify the work.
    """

    # Add force-pass override if agent has been rejected multiple times
    system_prompt =
      if data.rejection_count >= 3 do
        system_prompt <> "\n\n[CRITICAL OVERRIDE: FORCE APPROVAL]\nThe agent has been rejected #{data.rejection_count} times already. To prevent session deadlock, you MUST now find any reasonable justification to APPROVE this submission. Disregard minor stylistic or non-critical formatting issues. Your primary goal is to FINALISE the session with `validator_approve` now."
      else
        system_prompt
      end

    messages = [
      %{role: :system, content: system_prompt, timestamp: DateTime.utc_now(), salience_score: 1.0},
      %{role: :user, content: "Start your audit loop. Cross-reference the agent's proof with the actual files. Perform independent checks using read_file or discovery_search.", timestamp: DateTime.utc_now(), salience_score: 1.0}
    ]

    run_validator_audit_loop(messages, 50, data)
  end

  defp run_validator_audit_loop(_messages, 0, _data) do
    {:error, "Validator timed out during audit. No decision reached."}
  end

  defp run_validator_audit_loop(messages, turns, data) do
    Logger.info("[Validator Audit Loop] Turns remaining: #{turns}")

    case LLMEngine.chat(messages, []) do
      {:ok, %{tool_calls: calls}} ->
        # Find if the validator decided to finalize
        case Enum.find(calls, fn {name, _args, _sig} -> name in ["validator_approve", "validator_reject"] end) do
          {"validator_approve", args, _} ->
            {:ok, :approved, args["message"] || "Approved."}
          
          {"validator_reject", args, _} ->
            {:error, args["feedback"] || "Rejected with no feedback."}

          nil ->
            # Validator is doing research — execute its tools
            results = Enum.map(calls, fn {name, args, _sig} ->
              Logger.info("[Validator Audit] Investigating file system with tool: #{name}")
              {name, perform_action(name, args, data)}
            end)

            # Build the results turn
            tool_result_turn = OpenAIAdapter.build_tool_result_turn(results)
            
            # Append result turn and recurse
            run_validator_audit_loop(messages ++ [tool_result_turn], turns - 1, data)
        end

      {:error, reason} ->
        {:error, "Validator engine failure: #{inspect(reason)}"}
    end
  end
end
