defmodule ProCoder.Brain.Client.Adapters.OpenAIAdapter do
  @moduledoc """
  OpenAI Chat Completions adapter for OpenAI-compatible servers such as vLLM.

  Converts ProCoder's shared Gemini-shaped tool declarations and conversation
  history into OpenAI messages/tools, then normalizes returned function calls
  to the `{name, arguments, nil}` tuples consumed by AgentFSM.
  """
  @behaviour ProCoder.Brain.Client.Adapter

  alias ProCoder.Brain.Client.HTTPPool.Manager
  alias ProCoder.Brain.Client.SSEParser
  alias ProCoder.Core.AgentLogic.ToolDefinitions

  @impl true
  def chat(context, opts) do
    with {:ok, pool} <- Manager.checkout(Keyword.get(opts, :pool_name, :default_pool)) do
      chat_with_keys(context, opts, pool, [nil], [], 0)
    end
  end

  @impl true
  def stream(caller, context, opts) do
    with {:ok, pool} <- Manager.checkout(Keyword.get(opts, :pool_name, :default_pool)),
         {:ok, parser} <-
           SSEParser.start_link(
             caller: caller,
             config: ProCoder.Brain.Client.Requirements.stream_config()
           ) do
      payload = request_payload(context) |> Map.put(:stream, true)

      request =
        Finch.build(
          :post,
          endpoint_url(),
          request_headers(),
          Jason.encode!(payload)
        )

      ref = make_ref()

      spawn_link(fn ->
        result =
          Finch.stream(request, pool, nil, fn
            {:status, 200}, acc ->
              {:ok, acc}

            {:status, status}, acc ->
              send(caller, {:sse_error, {:http_status, status}})
              {:ok, acc}

            {:headers, _headers}, acc ->
              {:ok, acc}

            {:data, data}, acc ->
              SSEParser.process_chunk(parser, data)
              {:ok, acc}

            _event, acc ->
              {:ok, acc}
          end)

        case result do
          {:error, reason} -> send(caller, {:sse_error, {:stream_failed, reason}})
          _ -> :ok
        end
      end)

      {:ok, ref}
    end
  end

  @impl true
  def validate_payload(messages) when is_list(messages), do: :ok
  def validate_payload(_), do: {:error, :malformed_payload}

  @doc "Builds the canonical internal tool-result turn consumed by AgentFSM."
  def build_tool_result_turn(results) do
    parts =
      Enum.map(results, fn {name, result} ->
        response =
          case result do
            {:ok, value} -> %{"output" => to_string(value), "ok" => true}
            {:error, reason} -> %{"error" => to_string(reason), "ok" => false}
            other -> %{"output" => inspect(other), "ok" => true}
          end

        %{"functionResponse" => %{"name" => name, "response" => response}}
      end)

    %{role: "user", parts: parts}
  end

  defp request_payload(context) do
    %{
      model: System.get_env("PROCODER_LLM_MODEL", "qwen3.8-27b"),
      messages: to_openai_messages(context),
      tools: openai_tools(),
      tool_choice: System.get_env("PROCODER_LLM_TOOL_CHOICE", "required"),
      chat_template_kwargs: %{
        enable_thinking: System.get_env("PROCODER_LLM_THINKING", "false") == "true"
      }
    }
  end

  defp chat_with_keys(context, opts, pool, [], errors, retries) do
    rate_limited = Enum.any?(errors, fn {_key, reason} -> reason == :rate_limited end)

    if rate_limited and retries < 5 do
      Process.sleep((retries + 1) * 10_000)
      chat_with_keys(context, opts, pool, [nil], [], retries + 1)
    else
      {:error, {:provider_requests_failed, errors}}
    end
  end

  defp chat_with_keys(context, opts, pool, [_key | remaining], errors, retries) do
    request =
      Finch.build(
        :post,
        endpoint_url(),
        request_headers(),
        Jason.encode!(request_payload(context))
      )

    case Finch.request(request, pool, receive_timeout: Keyword.get(opts, :timeout, 120_000)) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %Finch.Response{status: 429}} ->
        chat_with_keys(
          context,
          opts,
          pool,
          remaining,
          errors ++ [{:api_key, :rate_limited}],
          retries
        )

      {:ok, %Finch.Response{status: status, body: body}} ->
        chat_with_keys(
          context,
          opts,
          pool,
          remaining,
          errors ++ [{:api_key, {:http_status, status, error_detail(body)}}],
          retries
        )

      {:error, %{reason: :timeout}} ->
        chat_with_keys(context, opts, pool, remaining, errors ++ [{:api_key, :timeout}], retries)

      {:error, reason} ->
        chat_with_keys(
          context,
          opts,
          pool,
          remaining,
          errors ++ [{:api_key, {:request_failed, reason}}],
          retries
        )
    end
  end

  defp request_headers do
    headers = [{"content-type", "application/json"}]

    case System.get_env("PROCODER_OPENAI_API_KEY") do
      key when is_binary(key) ->
        case String.trim(key) do
          "" -> headers
          value -> headers ++ [{"authorization", "Bearer " <> value}]
        end

      _ ->
        headers
    end
  end

  defp openai_tools do
    Enum.map(ToolDefinitions.all_tools(), fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.description,
          parameters: normalize_schema(tool.parameters)
        }
      }
    end)
  end

  defp normalize_schema(schema) when is_map(schema) do
    schema
    |> Enum.map(fn {key, value} ->
      normalized =
        if key == :type or key == "type",
          do: normalize_type(value),
          else: normalize_schema_value(value)

      {key, normalized}
    end)
    |> Map.new()
  end

  defp normalize_schema_value(value) when is_map(value), do: normalize_schema(value)

  defp normalize_schema_value(value) when is_list(value),
    do: Enum.map(value, &normalize_schema_value/1)

  defp normalize_schema_value(value), do: value

  defp normalize_type(type) when is_atom(type), do: type |> Atom.to_string() |> normalize_type()
  defp normalize_type(type) when is_binary(type), do: String.downcase(type)
  defp normalize_type(type), do: type

  # The agent keeps Gemini-native turns internally. Translate those at the edge
  # and preserve deterministic IDs so their following functionResponse turns
  # can refer to the matching OpenAI tool call.
  defp to_openai_messages(messages) do
    {converted, _pending} =
      Enum.reduce(messages, {[], %{}}, fn message, {out, pending} ->
        case convert_message(message, pending) do
          {nil, next_pending} ->
            {out, next_pending}

          {converted_messages, next_pending} ->
            {out ++ List.wrap(converted_messages), next_pending}
        end
      end)

    normalize_openai_messages(converted)
  end

  # AgentFSM and the shared orchestrator retain Gemini-style context, where
  # multiple system segments can be interleaved with conversation turns. vLLM's
  # OpenAI chat endpoint expects system instructions at the front and a user
  # query in the conversation.
  defp normalize_openai_messages(messages) do
    {system_messages, conversation} = Enum.split_with(messages, &system_message?/1)

    system_content =
      system_messages
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n\n")

    leading_system = if system_content == "", do: [], else: [%{role: "system", content: system_content}]
    normalized = leading_system ++ conversation

    if Enum.any?(conversation, &user_query?/1) do
      normalized
    else
      query = goal_from_system_messages(system_messages) || "Continue with the task described in the system instructions."
      normalized ++ [%{role: "user", content: query}]
    end
  end

  defp system_message?(%{role: role}) when role in [:system, "system"], do: true
  defp system_message?(_), do: false

  defp user_query?(%{role: role, content: content}) when role in [:user, "user"] and is_binary(content),
    do: String.trim(content) != ""

  defp user_query?(_), do: false

  defp goal_from_system_messages(messages) do
    Enum.find_value(messages, fn message ->
      case Map.get(message, :content) do
        content when is_binary(content) ->
          case Regex.run(~r/^\s*OVERALL GOAL:\s*(.+)\s*$/m, content) do
            [_, goal] -> String.trim(goal)
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp convert_message(%{role: role, content: content}, pending)
       when role in [:system, :user, :assistant],
       do: {%{role: role, content: content}, pending}

  defp convert_message(%{"role" => role, "content" => content}, pending)
       when role in ["system", "user", "assistant"],
       do: {%{role: role, content: content}, pending}

  defp convert_message(message, pending) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    parts = Map.get(message, :parts) || Map.get(message, "parts")

    if is_list(parts) do
      convert_parts(role, parts, pending)
    else
      {nil, pending}
    end
  end

  defp convert_message(_, pending), do: {nil, pending}

  defp convert_parts(role, parts, pending)
       when role in ["model", :model, "assistant", :assistant] do
    calls = Enum.flat_map(parts, &function_call/1)
    text = parts |> Enum.flat_map(&text_part/1) |> Enum.join("\n")

    if calls == [] do
      if text == "", do: {nil, pending}, else: {%{role: "assistant", content: text}, pending}
    else
      {tool_calls, pending} =
        calls
        |> Enum.with_index()
        |> Enum.map_reduce(pending, fn {{name, arguments}, index}, acc ->
          id = "call_#{index}_#{name}"
          pending_ids = Map.get(acc, name, []) ++ [id]

          call = %{
            id: id,
            type: "function",
            function: %{name: name, arguments: Jason.encode!(arguments)}
          }

          {call, Map.put(acc, name, pending_ids)}
        end)

      message = %{
        role: "assistant",
        content: if(text == "", do: nil, else: text),
        tool_calls: tool_calls
      }

      {message, pending}
    end
  end

  defp convert_parts(role, parts, pending) when role in ["user", :user] do
    {tool_messages, pending} =
      Enum.map_reduce(parts, pending, fn part, acc ->
        case function_response(part) do
          nil ->
            {nil, acc}

          {name, response} ->
            {id, acc} = take_call_id(acc, name)

            {%{role: "tool", name: name, tool_call_id: id, content: encode_response(response)},
             acc}
        end
      end)

    text = parts |> Enum.flat_map(&text_part/1) |> Enum.join("\n")

    messages =
      Enum.reject(tool_messages, &is_nil/1) ++
        if(text == "", do: [], else: [%{role: "user", content: text}])

    {messages, pending}
  end

  defp convert_parts(_role, _parts, pending), do: {nil, pending}

  defp function_call(part) when is_map(part) do
    call = Map.get(part, "functionCall") || Map.get(part, :functionCall)

    if is_map(call) do
      name = Map.get(call, "name") || Map.get(call, :name)
      args = Map.get(call, "args") || Map.get(call, :args) || %{}
      if is_binary(name) and is_map(args), do: [{name, args}], else: []
    else
      []
    end
  end

  defp function_call(_), do: []

  defp function_response(part) when is_map(part) do
    response = Map.get(part, "functionResponse") || Map.get(part, :functionResponse)

    if is_map(response) do
      name = Map.get(response, "name") || Map.get(response, :name)
      body = Map.get(response, "response") || Map.get(response, :response) || %{}
      if is_binary(name), do: {name, body}, else: nil
    end
  end

  defp function_response(_), do: nil

  defp text_part(part) when is_map(part) do
    case Map.get(part, "text") || Map.get(part, :text) do
      text when is_binary(text) -> [text]
      _ -> []
    end
  end

  defp text_part(_), do: []

  defp take_call_id(pending, name) do
    case Map.get(pending, name, []) do
      [id | rest] ->
        {id, if(rest == [], do: Map.delete(pending, name), else: Map.put(pending, name, rest))}

      [] ->
        {"call_#{name}", pending}
    end
  end

  defp encode_response(response) when is_map(response), do: Jason.encode!(response)
  defp encode_response(response), do: to_string(response)

  defp error_detail(body) when is_binary(body), do: String.slice(body, 0, 1_500)
  defp error_detail(_), do: ""

  defp parse_response(body) do
    with {:ok, %{"choices" => [%{"message" => message} | _]}} <- Jason.decode(body),
         {:ok, calls} <- parse_tool_calls(Map.get(message, "tool_calls") || []) do
      {:ok, %{thought: Map.get(message, "content") || "", tool_calls: calls}}
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp parse_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      function = if is_map(call), do: Map.get(call, "function", %{}), else: nil
      name = if is_map(function), do: Map.get(function, "name"), else: nil
      arguments = if is_map(function), do: Map.get(function, "arguments", "{}"), else: nil

      with true <- is_binary(name),
           {:ok, args} when is_map(args) <- decode_arguments(arguments) do
        {:cont, {:ok, acc ++ [{name, args, nil}]}}
      else
        _ -> {:halt, {:error, :malformed_tool_call}}
      end
    end)
  end

  defp parse_tool_calls(_), do: {:error, :malformed_tool_call}

  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}
  defp decode_arguments(arguments) when is_binary(arguments), do: Jason.decode(arguments)
  defp decode_arguments(_), do: {:error, :malformed_arguments}

  defp endpoint_url do
    base = System.get_env("PROCODER_LLM_URL", "http://129.212.187.75:8000/v1")
    String.trim_trailing(base, "/") <> "/chat/completions"
  end

end
