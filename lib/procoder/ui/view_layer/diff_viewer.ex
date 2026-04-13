defmodule ProCoder.UI.ViewLayer.DiffViewer do
  @moduledoc """
  Specialized rendering engine for interactive edit verification.
  Uses the Owl library to paint diffs and handle user approval keystrokes.
  """
  require Logger

  @doc """
  Renders a diff and blocks for user approval.
  Keystrokes:
  - y: Apply
  - n: Reject
  - e: Open in $EDITOR
  """
  def render_and_verify(diff_string) do
    # Paint the diff with colors
    colored_diff = colorize_diff(diff_string)
    
    Owl.IO.puts([
      "\n",
      Owl.Data.tag("--- [ Code Changes ] ---", :cyan),
      "\n",
      colored_diff,
      "\n",
      Owl.Data.tag("Apply changes? (y)es / (n)o / (e)dit: ", :bright)
    ])

    case wait_for_input() do
      "y" -> :ok
      "n" -> {:error, :rejected}
      "e" -> {:error, :open_editor}
      _ -> render_and_verify(diff_string) # Recurse on invalid input
    end
  end

  defp colorize_diff(diff) do
    diff
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "+") -> Owl.Data.tag(line, :green)
        String.starts_with?(line, "-") -> Owl.Data.tag(line, :red)
        true -> line
      end
    end)
    |> Enum.intersperse("\n")
  end

  defp wait_for_input do
    # In a real TUI, this would use Owl.IO.open_editor or low-level char input.
    # For this harness, we simulate with IO.getn
    IO.getn("> ", 1) |> String.trim() |> String.downcase()
  end
end
