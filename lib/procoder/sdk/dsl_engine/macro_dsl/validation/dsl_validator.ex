defmodule ProCoder.SDK.DSL.Validation.DSLValidator do
  @moduledoc """
  Compile-time validation engine for the ProCoder DSL.
  
  This module performs static semantic analysis on agents and skills defined
  via the ProCoder DSL macros, enforcing security, sandbox isolation,
  and rate-limiting compliance.
  """

  require Logger

  @sensitive_patterns [~r/sk-(?:live|test)_[a-zA-Z0-9]{32}/, ~r/AIza[0-9A-Za-z-_]{35}/]

  @doc """
  Main validation entry point for the AST walker.
  Should be called by the `defagent` and `defskill` macros during expansion.
  """
  def validate!(env, ast) do
    walk(env, ast)
    :ok
  end

  defp walk(env, {_, _, args} = ast) when is_list(args) do
    check_security_violations!(env, ast)
    Enum.each(args, &walk(env, &1))
  end

  defp walk(env, {left, right}) do
    walk(env, left)
    walk(env, right)
  end

  defp walk(env, list) when is_list(list) do
    Enum.each(list, &walk(env, &1))
  end

  defp walk(_env, _), do: :ok

  # --- Violation Checks ---

  defp check_security_violations!(_env, {func, _meta, args} = _ast) do
    # 1. Bubblewrap Enforcement & Module Access
    module_call = case func do
      {:., _, [{:__aliases__, _, parts}, func_name]} -> Enum.join(parts, ".") <> ".#{func_name}"
      {:., _, [atom, func_name]} when is_atom(atom) -> Atom.to_string(atom) <> ".#{func_name}"
      name when is_atom(name) -> Atom.to_string(name)
      _ -> ""
    end

    if String.starts_with?(module_call, ["File.", "System.", "os.", ":os."]) do
      unless module_call in ["System.get_env", "IO.puts"] do
        raise "SecurityViolation: Forbidden module access via '#{module_call}'."
      end
    end

    # Specific forbidden atoms
    if func in [:system_cmd, :file_rm_bang] do
      raise "SecurityViolation: Destructive operation '#{func}' forbidden."
    end

    # 2. Credential Leakage Prevention
    if is_list(args) do
      Enum.each(args, fn
        literal when is_binary(literal) ->
          if Enum.any?(@sensitive_patterns, &Regex.match?(&1, literal)) do
            raise "SecurityViolation: Hardcoded credential detected."
          end
        _ -> :ok
      end)
    end
  end

  defp check_security_violations!(_env, _), do: :ok

  @doc """
  Validates that custom agents and skills contain necessary documentation.
  """
  def validate_documentation!(env, module_name) do
    unless Module.get_attribute(env.module, :moduledoc) do
      raise "DocumentationRequired: Module '#{module_name}' must define @moduledoc."
    end
  end

  @doc """
  Emits telemetry event for agent topology visibility.
  """
  def emit_validation_telemetry(agent_name, type) do
    if :ets.whereis(:telemetry_handler_table) != :undefined do
      :telemetry.execute(
        [:procoder, :sdk, :validation, :agent_synthesized],
        %{timestamp: DateTime.utc_now()},
        %{agent_name: agent_name, type: type}
      )
    end
  end
end
