defmodule ProCoder.Brain.Client.Adapters.GeminiAdapter do
  @moduledoc """
  Adapter for Google's Gemini API using native Function Calling.

  Instead of asking the model to emit a JSON blob in text (fragile, unparseable),
  this adapter:
    1. Sends all agent tools as typed `function_declarations` to the Gemini API.
    2. Sets `function_calling_config.mode = ANY` to guarantee the model always
       returns a structured `functionCall` part — never raw prose.
    3. Returns a `{:ok, ToolCallResponse}` struct with the thought text and a list
       of `{tool_name, args_map}` tuples ready to dispatch — zero JSON parsing needed.

  Multi-turn history (tool results) must be passed in following the Gemini native
  `functionResponse` format (see `build_tool_result_turn/1`).
  """
  @behaviour ProCoder.Brain.Client.Adapter

  require Logger
  alias ProCoder.Core.AgentLogic.ToolDefinitions

  @base_url "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.1-pro-preview:generateContent"
  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @impl true
  def chat(messages, _opts) do
    all_keys = get_api_keys()
    chat_recursive(messages, all_keys, [], 0)
  end

  defp get_api_keys do
    # Use environment variables if set, otherwise fallback to the user-provided rotation pool.
    keys_str = System.get_env("PROCODER_LLM_API_KEYS") || System.get_env("PROCODER_LLM_API_KEY")
    
    if keys_str && keys_str != "" do
      keys_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      # No hardcoded keys allowed. Must be set via environment.
      []
    end
  end

  defp chat_recursive(messages, [], errors, retry_count) do
    is_rate_limited = Enum.any?(errors, fn {_key, reason} -> reason == :rate_limited end)
    
    if is_rate_limited and retry_count < 5 do
      wait_time = (retry_count + 1) * 10_000
      Logger.warn("[GeminiAdapter] All keys rate limited. Retrying (attempt #{retry_count + 1}) after #{wait_time / 1000}s...")
      Process.sleep(wait_time)
      chat_recursive(messages, get_api_keys(), [], retry_count + 1)
    else
      {:error, "All Gemini API keys failed and/or retry limit reached. Errors: #{inspect(errors)}"}
    end
  end

  defp chat_recursive(messages, [api_key | remaining_keys], errors, retry_count) do
    url = "#{@base_url}?key=#{api_key}"

    {system_parts, content_turns} = split_messages(messages)

    # Gemini API requirements:
    # 1. Must not be empty.
    # 2. Must alternate user/model/user/model.
    # 3. Must ALWAYS start with a user turn.
    content_turns = normalize_turn_sequence(content_turns)

    system_instruction =
      case system_parts do
        [] -> nil
        parts -> %{parts: parts}
      end

    payload =
      %{
        contents: content_turns,
        tools: [%{function_declarations: ToolDefinitions.all_tools()}],
        tool_config: %{
          function_calling_config: %{mode: "ANY"}
        },
        generationConfig: %{
          maxOutputTokens: 65_536,
          thinkingConfig: %{
            includeThoughts: true,
            thinkingLevel: "high"
          }
        }
      }
      |> maybe_put(:system_instruction, system_instruction)

    Logger.debug("[GeminiAdapter] Sending #{length(content_turns)} content turns, #{length(ToolDefinitions.all_tools())} tools declared.")
    Logger.debug("[GeminiAdapter] Payload: #{inspect(payload, limit: :infinity)}")

    case Req.post(url, json: payload, receive_timeout: 300_000) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("\n" <> String.duplicate("=", 80) <> "\n[GeminiAdapter] RAW API RESPONSE BODY:\n#{Jason.encode!(body)}\n" <> String.duplicate("=", 80) <> "\n")
        parse_response(body)

      {:ok, %{status: 429, body: body}} ->
        Logger.warn("[GeminiAdapter] Key #{String.slice(api_key, 0, 8)}... rate limited. Body: #{inspect(body)}")
        # Try the next key immediately without waiting!
        chat_recursive(messages, remaining_keys, errors ++ [{api_key, :rate_limited}], retry_count)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[GeminiAdapter] API error #{status} with key #{String.slice(api_key, 0, 8)}...: #{inspect(body)}")
        # For other errors, maybe try next key or fail
        chat_recursive(messages, remaining_keys, errors ++ [{api_key, {:status, status}}], retry_count)

      {:error, reason} ->
        Logger.error("[GeminiAdapter] Request failed with key #{String.slice(api_key, 0, 8)}...: #{inspect(reason)}")
        chat_recursive(messages, remaining_keys, errors ++ [{api_key, {:error, reason}}], retry_count)
    end
  end


  @impl true
  def stream(_caller, _messages, _opts), do: {:error, :not_implemented}

  @impl true
  def validate_payload(_messages), do: :ok

  @doc """
  Build the Gemini-native `functionResponse` content turn to append to history
  after executing a batch of tool calls.

  `results` is a list of `{tool_name :: String.t(), result :: {:ok, any} | {:error, any}}` tuples.
  Returns a map in Gemini's `role: "user"` / `parts: [functionResponse]` format.
  """
  def build_tool_result_turn(results) do
    parts =
      Enum.map(results, fn {name, result} ->
        response_content =
          case result do
            {:ok, value}    -> %{"output" => to_string(value), "ok" => true}
            {:error, reason} -> %{"error" => to_string(reason), "ok" => false}
            other           -> %{"output" => inspect(other), "ok" => true}
          end

        %{
          "functionResponse" => %{
            "name" => name,
            "response" => response_content
          }
        }
      end)

    %{role: "user", parts: parts}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Split messages into Gemini system instruction parts + ordered content turns.
  # Handles three kinds of history entries:
  #   1. ProCoder.Core.Types.Message structs (legacy / system / early user turns)
  #   2. Native Gemini content maps (%{role: ..., parts: [...]}) — tool result turns
  defp split_messages(messages) do
    Enum.reduce(messages, {[], []}, fn msg, {sys_acc, turn_acc} ->
      cond do
        # Native Gemini turn map (functionResponse / functionCall turns)
        is_map(msg) and not is_struct(msg) and Map.has_key?(msg, :role) and Map.has_key?(msg, :parts) ->
          # The Orchestrator adds :timestamp and :salience_score to these maps for internal sorting.
          # Google's API strictly rejects unknown fields. Strip out everything except role & parts.
          clean_msg = Map.take(msg, [:role, "role", :parts, "parts"])
          {sys_acc, turn_acc ++ [clean_msg]}

        # ProCoder.Core.Types.Message struct OR raw Message map
        (is_struct(msg) or (is_map(msg) and Map.has_key?(msg, :role) and Map.has_key?(msg, :content))) ->
          role = Map.get(msg, :role)
          content = Map.get(msg, :content)
          
          case role do
            :system ->
              {sys_acc ++ [%{"text" => content}], turn_acc}

            :assistant ->
              # Assistant turns from the model: store as model role with text part
              turn = %{role: "model", parts: [%{"text" => msg.content}]}
              {sys_acc, turn_acc ++ [turn]}

            _ ->
              # :user or anything else
              turn = %{role: "user", parts: [%{"text" => msg.content}]}
              {sys_acc, turn_acc ++ [turn]}
          end

        true ->
          Logger.warn("[GeminiAdapter] Unrecognised message shape: #{inspect(msg)}")
          {sys_acc, turn_acc}
      end
    end)
  end

  # Gemini 3 requires strict alternation of conversational turns.
  defp normalize_turn_sequence([]) do
    [%{role: "user", parts: [%{"text" => "Begin your task."}]}]
  end

  defp normalize_turn_sequence(turns) do
    # 1. Ensure it starts with a user turn.
    turns = 
      case List.first(turns) do
        %{role: "model"} = _ -> [%{role: "user", parts: [%{"text" => "[System Notice] Session resumed. Continue."}]} | turns]
        %{"role" => "model"} = _ -> [%{role: "user", parts: [%{"text" => "[System Notice] Session resumed. Continue."}]} | turns]
        _ -> turns
      end

    # 2. Collapse/pad consecutive identical roles to enforce strict alternation
    Enum.reduce(turns, [], fn turn, acc ->
      current_role = Map.get(turn, :role) || Map.get(turn, "role")
      
      case acc do
        [] -> 
          [turn]
          
        [last_turn | _] = acc_list ->
          last_role = Map.get(last_turn, :role) || Map.get(last_turn, "role")
          
          if current_role == last_role do
            # Interleave a dummy turn of the opposite role to satisfy API strictness
            filler_role = if current_role == "model", do: "user", else: "model"
            filler_turn = %{role: filler_role, parts: [%{"text" => "Acknowledged."}]}
            [turn, filler_turn | acc_list]
          else
            [turn | acc_list]
          end
      end
    end)
    |> Enum.reverse()
  end

  # Parse the Gemini response body and extract the ToolCallResponse.
  defp parse_response(%{"candidates" => [candidate | _]}) do
    Logger.debug("[GeminiAdapter] Full candidate: #{inspect(candidate, limit: :infinity)}")
    parts = get_in(candidate, ["content", "parts"]) || []
    Logger.debug("[GeminiAdapter] Raw parts from API: #{inspect(parts, limit: :infinity)}")

    thought = extract_thought(parts)
    tool_calls = extract_function_calls(parts)

    {:ok, %{thought: thought, tool_calls: tool_calls}}
  end

  defp parse_response(body) do
    Logger.error("[GeminiAdapter] Unexpected response structure: #{inspect(body)}")
    {:error, :malformed_response}
  end

  defp extract_thought(parts) do
    # Gemini 3 Thinking mode returns thoughts in a dedicated 'thought' part (boolean or string).
    # We aggregate all possible reasoning sources to ensure nothing is missed.
    parts
    |> Enum.map(fn part ->
      # 1. Official v1beta thinking: a part with a boolean 'thought' field and 'text' content.
      # 2. Experimental thinking: a part with a string 'thought' or 'thought_text' field.
      # 3. Simple fallback: 'reasoning' or 'text' parts.
      cond do
        Map.get(part, "thought") == true -> Map.get(part, "text")
        is_binary(Map.get(part, "thought")) -> Map.get(part, "thought")
        is_binary(Map.get(part, "thought_text")) -> Map.get(part, "thought_text")
        is_binary(Map.get(part, "reasoning")) -> Map.get(part, "reasoning")
        # Only take 'text' if it's not a tool-related part
        not Map.has_key?(part, "functionCall") and not Map.has_key?(part, "functionResponse") -> 
          Map.get(part, "text")
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp extract_function_calls(parts) do
    # Gemini 3 only emits the thought_signature on the first functionCall part during
    # parallel tool use, but strictly requires it to be echoed back on EVERY part.
    # We find the master signature for the turn and broadcast it to all calls.
    master_sig = Enum.find_value(parts, fn part ->
      fc = Map.get(part, "functionCall", %{})
      Map.get(fc, "thought_signature") || Map.get(fc, "thoughtSignature") || 
      Map.get(part, "thought_signature") || Map.get(part, "thoughtSignature")
    end)

    parts
    |> Enum.filter(&Map.has_key?(&1, "functionCall"))
    |> Enum.map(fn %{"functionCall" => fc} ->
      name = Map.get(fc, "name")
      args = Map.get(fc, "args", %{})
      {name, args, master_sig}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
