defmodule ProCoder.SDK.MacroDSL.Persistence.Hooks.Validation.DSLValidator do
  @moduledoc """
  Compile-time static analysis validator for the Persistence DSL.

  Enforces security, lifecycle, and structural integrity for agents utilizing
  ProCoder's Persistence macros. Performs deep AST analysis to detect forbidden
  path operations, missing transactional blocks, and potential data leakage
  at compile-time.
  """

  require Logger
  @forbidden_functions [:file_rm, :file_rm_rf, :system_cmd, :file_write_bang]
  @sensitive_patterns [~r/sk-(?:live|test)_[a-zA-Z0-9]{32}/, ~r/AIza[0-9A-Za-z-_]{35}/]
  @required_lifecycle_callbacks [:init, :terminate, :handle_event]

  @doc """
  Main validation entry point for the Persistence DSL.
  Called during macro expansion to ensure agent module compliance.
  """
  def validate!(env, ast) do
    module = env.module
    
    validate_lifecycle!(module)
    walk_ast(env, ast)
    :ok
  end

  # --- Private Analysis Pipeline ---

  defp walk_ast(env, {_func, _meta, args} = ast) when is_list(args) do
    check_security_violations!(env, ast)
    check_atomic_persistence!(env, ast)
    Enum.each(args, &walk_ast(env, &1))
  end

  defp walk_ast(env, {left, right}) do
    walk_ast(env, left)
    walk_ast(env, right)
  end

  defp walk_ast(env, list) when is_list(list) do
    Enum.each(list, &walk_ast(env, &1))
  end

  defp walk_ast(_env, _), do: :ok

  # --- Violation Checks ---

  defp check_security_violations!(env, {func, meta, args}) do
    # 1. Bubblewrap Enforcement: Forbidden destructive filesystem/system calls
    if func in @forbidden_functions do
      raise CompileError, file: env.file, line: meta[:line], description: "PersistenceDSL SecurityViolation: Forbidden function '#{func}' called."
    end

    # 2. Credential Leakage Prevention
    case args do
      [literal | _] when is_binary(literal) ->
        if Enum.any?(@sensitive_patterns, &Regex.match?(&1, literal)) do
          raise CompileError, file: env.file, line: meta[:line], description: "PersistenceDSL SecurityViolation: Hardcoded credential leakage detected."
        end
      _ -> :ok
    end
  end

  defp check_atomic_persistence!(env, {func, meta, _args}) do
    # Enforce transactional blocks
    if func == :persist and not inside_transaction?(env) do
      raise CompileError, file: env.file, line: meta[:line], description: "PersistenceDSL Error: 'persist' hook must be inside ProCoder.Repo.transaction_atomic/1 block."
    end
  end

  defp validate_lifecycle!(module) do
    for callback <- @required_lifecycle_callbacks do
      unless Module.defines?(module, {callback, 3}) or Module.defines?(module, {callback, 4}) do
        raise "PersistenceDSL LifecycleError: Module '#{module}' is missing mandatory callback '#{callback}' required by the SessionManager supervisor tree."
      end
    end
  end

  # --- Helpers ---

  defp inside_transaction?(env) do
    # Check if the macro is wrapped in ProCoder.Repo.transaction_atomic/1
    # This logic inspects the call stack or scope metadata
    Enum.any?(env.context_modules, fn m -> m == ProCoder.Repo end)
  end

  @doc """
  Emits telemetry for persistence validation failures, integrated with
  the ProCoder Swarm Controller.
  """
  def emit_validation_error(agent_name, details) do
    if :ets.whereis(:telemetry_handler_table) != :undefined do
      :telemetry.execute(
        [:procoder, :persistence, :validation, :failure],
        %{timestamp: DateTime.utc_now()},
        %{agent_name: agent_name, details: details}
      )
    end
  end
end
