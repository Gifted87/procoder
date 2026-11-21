defmodule ProCoder.SDK.MacroDSL.Agents.AgentMacro do
  @moduledoc """
  The `defagent` macro provides a declarative DSL for defining autonomous, headless 
  coding agents within the ProCoder swarm architecture.
  """

  require Logger
  alias ProCoder.SDK.DSL.Validation.DSLValidator
  alias ProCoder.SDK.DSL.Lifecycle.LifecycleUtils

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__), only: [defagent: 2, defskill: 2, persona: 1]
    end
  end

  defmacro defagent(name, do: block) do
    # 1. Compile-time validation
    DSLValidator.validate!(__CALLER__, block)

    quote do
      defmodule unquote(name) do
        require Logger
        @moduledoc """
        Automatically synthesized ProCoder Agent: #{inspect(unquote(name))}.
        Managed by ProCoder SessionManager via the supervision tree.
        """
        
        # Inject gen_statem boilerplate
        unquote(LifecycleUtils.generate_boilerplate())
        
        # Setup attribute tracking for skills and persona
        Module.register_attribute(__MODULE__, :agent_skills, accumulate: true)
        Module.register_attribute(__MODULE__, :persona, accumulate: false)
        Module.put_attribute(__MODULE__, :persona, "You are a specialized autonomous coding agent.")

        # Import defskill into the agent's scope
        import ProCoder.SDK.MacroDSL.Agents.AgentMacro, only: [defskill: 2, persona: 1]

        # 2. Macro expansion of agent behaviors
        unquote(block)

        # 3. Agent Metadata & Skill Introspection
        def persona, do: @persona

        def __skills__, do: Enum.reverse(@agent_skills)

        def __tool_declarations__ do
          Enum.map(__skills__(), fn skill_atom ->
            %{
              name: Atom.to_string(skill_atom),
              description: "Specialist skill '#{skill_atom}' provided by #{inspect(unquote(name))}. Pass arguments as a map.",
              parameters: %{
                type: "OBJECT",
                properties: %{
                  path: %{type: "STRING", description: "Target path or resource"},
                  query: %{type: "STRING", description: "Search query or concept"},
                  cmd: %{type: "STRING", description: "Shell command if applicable"},
                  args: %{type: "OBJECT", description: "Skill arguments map"}
                }
              }
            }
          end)
        end

        def execute_skill(skill_name, args) when is_binary(skill_name) do
          case Enum.find(__skills__(), &(Atom.to_string(&1) == skill_name)) do
            nil -> {:error, "Skill '#{skill_name}' not found on agent #{inspect(__MODULE__)}"}
            atom_name -> execute_skill(atom_name, args)
          end
        end

        def execute_skill(skill_atom, args) when is_atom(skill_atom) do
          if skill_atom in __skills__() do
            apply(__MODULE__, skill_atom, [args])
          else
            {:error, "Skill '#{skill_atom}' not found on agent #{inspect(__MODULE__)}"}
          end
        end

        # 4. FSM / ReAct Loop Process Bridge
        def start_link(opts) do
          fsm_opts = Keyword.put(opts, :specialist_module, __MODULE__)
          ProCoder.Core.AgentFSM.start_link(fsm_opts)
        end

        def child_spec(opts) do
          %{
            id: {:specialist_agent, Keyword.get(opts, :session_id, __MODULE__)},
            start: {__MODULE__, :start_link, [opts]},
            restart: :transient
          }
        end

        # 5. Telemetry registration
        @after_compile {DSLValidator, :emit_validation_telemetry}

        # 6. Standard gen_statem events
        @impl true
        def handle_event({:call, from}, {:rehydrate_state, state}, _state_name, data) do
          {:next_state, :idle, Map.merge(data, state), [{:reply, from, :ok}]}
        end

        @impl true
        def handle_event(:cast, :suspend_execution, _state_name, data) do
          {:next_state, :suspended, data}
        end

        @impl true
        def handle_event(:cast, :resume_execution, :suspended, data) do
          {:next_state, :idle, data}
        end
        
        @impl true
        def handle_event(type, content, state_name, data) do
          Logger.debug("Agent #{inspect(unquote(name))} in #{state_name} received unhandled event: #{inspect(type)}")
          {:keep_state, data}
        end
      end
    end
  end

  defmacro defskill(name_ast, do: block) do
    name = case name_ast do
      {atom, _, _} when is_atom(atom) -> atom
      atom when is_atom(atom) -> atom
      _ -> raise "defskill name must be an atom, got: #{inspect(name_ast)}"
    end

    res = quote do
      @agent_skills unquote(name)

      def unquote(name)(var!(args)) do
        # Suppress unused warning for 'args'
        _ = var!(args)
        
        # Wrap execution in security-hardened Actuator context
        case ProCoder.Actuator.PolicyLogic.PolicyEngine.evaluate_action(%{
          type: :skill_execution,
          cmd: Atom.to_string(unquote(name)),
          risk: 0.1,
          uncertainty: 0.1,
          repetition: 0,
          idle_time_ms: 0
        }) do
          :execute ->
            try do
              unquote(block)
            rescue
              e -> 
                Logger.error("Skill execution failure in #{unquote(name)}: #{inspect(e)}")
                reraise e, __STACKTRACE__
            end
          :verify ->
            Logger.warn("Skill execution for #{unquote(name)} deferred: Policy review required.")
            {:error, :review_required}
          :suspend ->
            Logger.error("Skill execution for #{unquote(name)} rejected by PolicyEngine.")
            {:error, :security_violation}
        end
      end
    end
    # IO.puts("SYNTHESIZED SKILL [#{name}]:\n#{Macro.to_string(res)}")
    res
  end

  defmacro persona(text) do
    quote do
      Module.put_attribute(__MODULE__, :persona, unquote(text))
    end
  end
end
