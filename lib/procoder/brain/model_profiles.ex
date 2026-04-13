defmodule ProCoder.Brain.ModelProfiles do
  @moduledoc """
  Defines model-specific configuration and prompt templates for adaptive context engineering.
  """

  defstruct [
    :name,
    :tool_format,
    :system_persona,
    :cot_enabled,
    :research_mode,
    :max_tokens
  ]

  @type t :: %__MODULE__{}

  def get_profile(model_name) do
    case model_name do
      "claude-3-haiku" <> _ -> haiku_profile()
      "claude-3-5-sonnet" <> _ -> sonnet_profile()
      "claude-3-opus" <> _ -> opus_profile()
      "gemini-" <> _ -> gemini_profile()
      _ -> gemini_profile()
    end
  end

  defp haiku_profile do
    %__MODULE__{
      name: "Claude 3 Haiku",
      tool_format: :json_schema,
      system_persona: "You are a code execution engine. Be concise and prioritize speed.",
      cot_enabled: false,
      research_mode: false,
      max_tokens: 200_000
    }
  end

  defp sonnet_profile do
    %__MODULE__{
      name: "Claude 3.5 Sonnet",
      tool_format: :markdown_xml,
      system_persona: "You are a Senior Software Engineer. Provide well-reasoned solutions.",
      cot_enabled: true,
      research_mode: true,
      max_tokens: 200_000
    }
  end

  defp opus_profile do
    %__MODULE__{
      name: "Claude 3 Opus",
      tool_format: :verbose_xml,
      system_persona: "You are a world-class software architect. Use deep reasoning and reflexion.",
      cot_enabled: true,
      research_mode: true,
      max_tokens: 200_000
    }
  end

  defp gemini_profile do
    %__MODULE__{
      name: "Gemini 3.1 Flash Lite",
      tool_format: :json_schema,
      system_persona: "You are Gemini 3.1 Flash Lite, a fast and highly capable reasoning model. You reason with meticulous precision and operate at peak efficiency.",
      cot_enabled: true,
      research_mode: true,
      max_tokens: 200_000
    }
  end
end
