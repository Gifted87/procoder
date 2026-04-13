defmodule ProCoder.CyberSecurityAgentDemo do
  @moduledoc """
  A custom agent built using the ProCoder Macro DSL for security analysis.
  This agent demonstrates how the DSL can be used to specialize agents for complex domains.
  """
  use ProCoder.SDK.MacroDSL.Agents.AgentMacro

  defagent CyberSecurityAgent do
    @moduledoc "An agent specialized in source code vulnerability scanning."

    defskill scan_vulnerabilities do
      # This skill would normally use tree-sitter or regex-based rules
      # For the demo, it reads the file and looks for common patterns
      file_path = args["path"]
      case ProCoder.Actuator.AgentIO.read_file(file_path) do
        {:ok, content} ->
          findings = []
          # Rule 1: Hardcoded Keys
          findings = if String.match?(content, ~r/AIza[0-9A-Za-z\\-_]{35}/), do: findings ++ ["Potential API Key detected"], else: findings
          
          # Rule 2: Shell execution with interpolation
          findings = if String.match?(content, ~r/System\.cmd\(.*\#\{.*\}/), do: findings ++ ["Potential Command Injection via interpolation in System.cmd"], else: findings
          
          # Rule 3: Unescaped term-to-binary
          findings = if String.contains?(content, ":erlang.binary_to_term"), do: findings ++ ["Unsafe binary_to_term usage detected"], else: findings

          if Enum.empty?(findings) do
            {:ok, "No immediate vulnerabilities found in #{file_path}"}
          else
            {:warn, "Findings in #{file_path}: #{Enum.join(findings, "; ")}"}
          end

        {:error, reason} -> 
          {:error, "Failed to read file: #{inspect(reason)}"}
      end
    end

    defskill analyze_ast do
      # Uses the Native CodeGraph Engine for deeper structural analysis
      path = args["path"]
      case ProCoder.Search.CodeGraphEngine.parse_file(path) do
        {:ok, _ast} -> {:ok, "AST for #{path} is structurally valid and compatible with ProCoder standards."}
        {:error, reason} -> {:error, "AST parsing failure: #{inspect(reason)}"}
      end
    end
  end
end
