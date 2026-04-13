defmodule ProCoder.Core.Search.WebSearch do
  @moduledoc """
  Skill for performing grounded web searches using the Gemini Search tool.
  This allows the agent to find documentation and community solutions for complex errors.
  """

  require Logger

  @base_url "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.1-flash-lite-preview:generateContent"

  @doc """
  Performs a Google Search via the Gemini API's native grounding capability.
  """
  def search(query) do
    Logger.info("[WebSearch] Performing Google Search for: #{query}")

    api_key = get_api_key()
    if is_nil(api_key) do
      {:error, "PROCODER_LLM_API_KEY is not configured. Web search is disabled."}
    else
      url = "#{@base_url}?key=#{api_key}"

      # Grounding payload for Gemini. 
      # We use a dedicated prompt to ensure it focuses on documentation and technical facts.
      payload = %{
        contents: [
          %{
            role: "user", 
            parts: [%{text: "Perform a detailed Google Search to fetch technical documentation, official specifications, or community solutions for the following problem: \\n\\n #{query} \\n\\n Return a comprehensive technical summary including relevant URL references."}]
          }
        ],
        tools: [%{google_search: %{}}],
        generationConfig: %{
          maxOutputTokens: 2048,
          temperature: 0.2
        }
      }

      case Req.post(url, json: payload, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: body}} ->
          parse_grounding_response(body)

        {:ok, %{status: status, body: body}} ->
          Logger.error("[WebSearch] API error #{status}: #{inspect(body)}")
          {:error, "Web search API returned error status #{status}."}

        {:error, reason} ->
          Logger.error("[WebSearch] Request failed: #{inspect(reason)}")
          {:error, "Web search request failed due to network error."}
      end
    end
  end

  defp get_api_key do
    # Check enviroment variables first, otherwise use the primary key from the user-provided pool
    env_keys = System.get_env("PROCODER_LLM_API_KEYS") || System.get_env("PROCODER_LLM_API_KEY")

    if env_keys && env_keys != "" do
      env_keys |> String.split(",") |> List.first() |> String.trim()
    else
      "AQ.Ab8RN6Lr5M5XvcIqEmu3GjrdYW7EfrpZcacvv5NdMiOqYJdV6Q"
    end
  end

  defp parse_grounding_response(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    # Extract the grounded text response
    text = 
      parts
      |> Enum.map(fn part -> part["text"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\\n\\n")

    if text == "" do
      {:error, "Search completed but returned an empty response."}
    else
      {:ok, text}
    end
  end

  defp parse_grounding_response(body) do
    Logger.error("[WebSearch] Unexpected response structure: #{inspect(body)}")
    {:error, "Malformed search response from API."}
  end
end
