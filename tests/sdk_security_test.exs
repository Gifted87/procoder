defmodule ProCoder.Tests.SdkSecurityTest do
  @moduledoc """
  Demonstrates the Developer SDK (Macro DSL) security enforcement.
  Validates that the DSLValidator catches hardcoded credentials at compile-time.
  """
  alias ProCoder.SDK.DSL.Validation.DSLValidator

  def run_test do
    IO.puts("--- SDK Security Test: Starting ---")
    
    # 1. Define an AST with a hardcoded Gemini key
    insecure_ast = quote do
      defskill leak_key do
        key = "AIzaSy_FAKE_TEST_KEY_FOR_VALIDATION_PURPOSES"
        IO.puts("Leaking key: #{key}")
      end
    end

    # 2. Define an AST with a forbidden module call
    forbidden_ast = quote do
      defskill delete_files do
        File.rm_rf!("/")
      end
    end

    # 3. Define a secure AST
    secure_ast = quote do
      defskill hello do
        IO.puts("Hello World")
      end
    end

    IO.puts("Testing hardcoded credential blocking...")
    case validate(insecure_ast) do
      {:error, msg} -> IO.puts("✅ Success: Credential blocked: #{msg}")
      :ok -> IO.puts("❌ Failure: Credential allowed!")
    end

    IO.puts("\nTesting forbidden module (File.rm_rf!) blocking...")
    case validate(forbidden_ast) do
      {:error, msg} -> IO.puts("✅ Success: Forbidden call blocked: #{msg}")
      :ok -> IO.puts("❌ Failure: Forbidden call allowed!")
    end

    IO.puts("\nTesting secure code allowance...")
    case validate(secure_ast) do
      :ok -> IO.puts("✅ Success: Secure code allowed.")
      {:error, msg} -> IO.puts("❌ Failure: Secure code blocked: #{msg}")
    end
  end

  defp validate(ast) do
    try do
      # Use the DSLValidator directly for high-fidelity demonstration
      DSLValidator.validate!(%Macro.Env{}, ast)
      :ok
    rescue
      e -> {:error, e.message}
    end
  end
end

ProCoder.Tests.SdkSecurityTest.run_test()
