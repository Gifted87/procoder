defmodule ProCoder.Brain.PromptLogic.Engine.Formatter do
  @moduledoc """
  Responsible for formatting prompt logic data structures into strings
  suitable for processing by the engine.
  """

  @doc """
  Formats a given data structure based on the required prompt engine schema.
  """
  def format(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {to_string(k), format_value(v)} end)
    |> Enum.into(%{})
  end

  @doc """
  Redacts sensitive information from the content.
  Baseline implementation: passes through for now.
  """
  def redact(content) when is_binary(content), do: content
  def redact(content), do: content

  defp format_value(value) when is_binary(value), do: String.trim(value)
  defp format_value(value) when is_list(value), do: Enum.map(value, &format_value/1)
  defp format_value(value) when is_map(value), do: format(value)
  defp format_value(value), do: value
end
