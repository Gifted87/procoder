defmodule ProCoder.SDK.DSL.Lifecycle.LifecycleUtils do
  @moduledoc """
  Functional primitives for the ProCoder SDK lifecycle macro DSL.
  Provides AST synthesis helpers for `gen_statem` callbacks and persistence hooks.
  """

  require Logger
  alias ProCoder.SDK.DSL.Validation.DSLValidator

  @doc """
  Constructs the `gen_statem` state function dispatch logic based on DSL-defined hooks.
  """
  def synthesize_state_handler(state_name, body) do
    quote do
      def unquote(state_name)(event_type, event_content, data) do
        # 1. Telemetry entry
        :telemetry.execute(
          [:procoder, :sdk, :lifecycle, unquote(state_name)],
          %{timestamp: DateTime.utc_now()},
          %{agent_id: data.session_id}
        )

        # 2. Handler execution
        try do
          unquote(body)
        rescue
          e ->
            Logger.error("Lifecycle error in state '#{unquote(state_name)}': #{Exception.message(e)}")
            :telemetry.execute([:procoder, :sdk, :lifecycle, :error], %{reason: inspect(e)})
            {:next_state, :safe_state, data}
        end
      end
    end
  end

  @doc """
  Generates the persistence wrapper for stateful variables.
  Ensures atomic writes to Brain.MemoryStore.
  """
  def persist_var(var_name, value, data) do
    quote do
      Brain.MemoryStore.Cache.CacheEngine.write_memory(
        unquote(data).session_id,
        unquote(var_name),
        unquote(value)
      )
    end
  end

  @doc """
  Performs compile-time security validation on the AST block provided in a lifecycle macro.
  """
  def validate_block!(env, block) do
    DSLValidator.validate!(env, block)
  end

  @doc """
  Generates the standard gen_statem boilerplate for an agent module.
  """
  def generate_boilerplate do
    quote do
      @behaviour :gen_statem

      @impl true
      def callback_mode, do: [:state_functions, :handle_event_function]

      @impl true
      def init(opts) do
        data = %ProCoder.Core.Types.AgentContext{
          id: Keyword.get(opts, :session_id), # Use session_id as the primary ID
          workspace_root: Keyword.get(opts, :worktree_root),
          created_at: DateTime.utc_now()
        }
        {:ok, :idle, data}
      end

      @impl true
      def terminate(reason, state, data) do
        Logger.info("Agent #{data.id} terminating in state #{state}: #{inspect(reason)}")
        :ok
      end
    end
  end
end
