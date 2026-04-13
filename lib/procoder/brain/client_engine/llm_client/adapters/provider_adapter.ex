defmodule ProCoder.Brain.Client.Adapters.ProviderAdapter do
  @moduledoc """
  Provider-specific adapter for ProCoder LLM interactions.
  Maps internal `ProCoder.Core.Types.Message` to vendor-specific formats and handles
  streaming, error correction, and telemetry.
  """

  @behaviour ProCoder.Brain.Client.Adapter

  require Logger
  alias ProCoder.Core.Types.Message
  alias ProCoder.Brain.Client.HTTPPool.Manager
  alias ProCoder.Brain.Client.SSEParser
  alias ProCoder.Brain.PromptLogic.Engine.Formatter, as: Validator

  @impl true
  def chat(context, opts) do
    pool_name = Keyword.get(opts, :pool_name, :default_pool)
    
    with {:ok, pool} <- Manager.checkout(pool_name) do
      payload = format_payload(context)
      headers = [
        {"content-type", "application/json"}, 
        {"authorization", "Bearer " <> get_api_key()}
      ]
      
      request = Finch.build(:post, get_base_url() <> "/chat/completions", headers, Jason.encode!(payload))
      
      case Finch.request(request, pool, receive_timeout: Keyword.get(opts, :timeout, 30_000)) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          handle_response(body)
        {:ok, %Finch.Response{status: 429}} ->
          {:error, :rate_limited}
        {:error, %{reason: :timeout}} ->
          {:error, :timeout}
        _ ->
          {:error, :malformed_payload}
      end
    end
  end

  @impl true
  def stream(caller, context, opts) do
    pool_name = Keyword.get(opts, :pool_name, :default_pool)
    
    with {:ok, pool} <- Manager.checkout(pool_name) do
      payload = format_payload(context) |> Map.put(:stream, true)
      headers = [
        {"content-type", "application/json"}, 
        {"authorization", "Bearer " <> get_api_key()}
      ]
      
      ref = make_ref()
      
      case SSEParser.start_link(caller: caller, config: ProCoder.Brain.Client.Requirements.stream_config()) do
        {:ok, parser} ->
          request = Finch.build(:post, get_base_url() <> "/chat/completions", headers, Jason.encode!(payload))
          
          spawn_link(fn ->
            Finch.stream(request, pool, nil, fn
              {:status, status}, _ -> {:ok, status}
              {:headers, _}, _ -> {:ok, :headers}
              {:data, data}, _ ->
                SSEParser.process_chunk(parser, data)
                {:ok, :data}
              error, _ ->
                Logger.error("Stream error: #{Validator.redact(inspect(error))}")
                {:ok, :error}
            end)
          end)
          
          {:ok, ref}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def validate_payload(messages) do
    if Enum.all?(messages, &valid_message?/1) do
      :ok
    else
      {:error, :malformed_payload}
    end
  end

  # --- Internal Helpers ---

  defp format_payload(messages) do
    %{
      model: "procoder-default",
      messages: Enum.map(messages, fn m ->
        %{role: m.role, content: m.content}
      end)
    }
  end

  defp handle_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => msg}]}} ->
        if valid_tool_calls?(Map.get(msg, "tool_calls")),
          do: {:ok, %Message{role: :assistant, content: msg["content"]}},
          else: {:error, :malformed_payload}
      _ ->
        {:error, :malformed_payload}
    end
  end

  defp valid_tool_calls?(nil), do: true
  defp valid_tool_calls?(calls) when is_list(calls), do: Enum.all?(calls, &is_map/1)
  defp valid_tool_calls?(_), do: false

  defp valid_message?(%Message{role: r}) when r in [:system, :user, :assistant], do: true
  defp valid_message?(_), do: false

  defp get_api_key, do: System.get_env("PROCODER_LLM_API_KEY", "dev_mock_token")
  defp get_base_url, do: System.get_env("PROCODER_LLM_URL", "http://localhost:8080")
end
