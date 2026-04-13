defmodule ProCoder.Brain.PromptEngine.Corrector do
  @moduledoc """
  The JSON Correction Module for the ProCoder PromptEngine.
  
  Responsible for intercepting malformed tool calls, validating against schemas,
  redacting sensitive information, and generating structured feedback prompts
  for the LLM to facilitate one-shot error correction.
  """

  require Logger

  alias ProCoder.Brain.Client.Telemetry.EventMonitor
  alias ProCoder.Brain.PromptEngine.Requirements

  @type correction_result :: {:ok, map()} | {:retry, String.t()} | {:error, :unrecoverable}

  @doc """
  Attempts to correct a malformed tool call string using schema validation feedback.
  
  Implementation follows a one-shot correction pattern:
  1. Parse/Sanitize
  2. Validate against schema
  3. If invalid, construct correction feedback prompt.
  """
  @spec correct_tool_call(String.t(), map(), integer()) :: correction_result()
  def correct_tool_call(raw_json, schema, retry_count \\ 0) do
    if retry_count >= Requirements.error_correction_config().max_retries do
      {:error, :unrecoverable}
    else
      case sanitize_and_parse(raw_json) do
        {:ok, parsed} ->
          case validate_schema(parsed, schema) do
            :ok -> {:ok, parsed}
            {:error, errors} -> generate_feedback(raw_json, errors, schema)
          end

        {:error, reason} ->
          generate_feedback(raw_json, ["Syntax error: #{reason}"], schema)
      end
    end
  end

  # --- Private Helpers ---

  defp sanitize_and_parse(json_string) do
    # PII/Credential redaction before parsing
    sanitized = redact_sensitive_data(json_string)
    
    try do
      {:ok, Jason.decode!(sanitized)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp redact_sensitive_data(input) do
    patterns = [
      ~r/(?:AIza[0-9A-Za-z-_]{35})/,
      ~r/(?:sk-(?:live|test)_[a-zA-Z0-9]{32})/
    ]

    Enum.reduce(patterns, input, fn pattern, acc ->
      String.replace(acc, pattern, "REDACTED")
    end)
  end

  defp validate_schema(parsed, schema) when is_map(parsed) and is_map(schema) do
    required_keys = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    violations =
      Enum.flat_map(required_keys, fn key ->
        cond do
          not Map.has_key?(parsed, key) ->
            ["Missing required field: '#{key}'"]

          # Type checks for declared string/integer/boolean properties
          Map.has_key?(properties, key) ->
            expected_type = get_in(properties, [key, "type"])
            actual = Map.get(parsed, key)
            if typed_ok?(actual, expected_type) do
              []
            else
              ["Field '#{key}' expected type #{expected_type}, got #{typeof(actual)}"]
            end

          true ->
            []
        end
      end)

    if violations == [], do: :ok, else: {:error, violations}
  end

  defp validate_schema(parsed, _schema) when not is_map(parsed) do
    {:error, ["Payload must be a JSON object"]}
  end

  defp typed_ok?(v, "string"), do: is_binary(v)
  defp typed_ok?(v, "integer"), do: is_integer(v)
  defp typed_ok?(v, "number"), do: is_number(v)
  defp typed_ok?(v, "boolean"), do: is_boolean(v)
  defp typed_ok?(v, "array"), do: is_list(v)
  defp typed_ok?(v, "object"), do: is_map(v)
  defp typed_ok?(_v, _type), do: true

  defp typeof(v) when is_binary(v), do: "string"
  defp typeof(v) when is_integer(v), do: "integer"
  defp typeof(v) when is_float(v), do: "number"
  defp typeof(v) when is_boolean(v), do: "boolean"
  defp typeof(v) when is_list(v), do: "array"
  defp typeof(v) when is_map(v), do: "object"
  defp typeof(_), do: "unknown"

  defp generate_feedback(raw_input, violations, schema) do
    EventMonitor.emit([:procoder, :prompt_engine, :correction_attempt], %{count: 1}, %{
      input: raw_input,
      violations: violations
    })

    feedback_prompt = """
    The previous tool call was invalid. Please correct the following issues:
    Violations: #{Enum.join(violations, ", ")}
    
    Original Input:
    #{raw_input}
    
    Expected Schema:
    #{Jason.encode!(schema)}
    
    Please provide the corrected JSON tool call only.
    """
    
    {:retry, feedback_prompt}
  end
end
