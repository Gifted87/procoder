
defmodule ProCoder.FullAnalyzer do
  def run(dir, depth \\ 0) do
    indent = String.duplicate("  ", depth)
    
    File.ls!(dir)
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.each(fn path ->
      if File.dir?(path) do
        IO.puts("#{indent}- **Directory: #{Path.basename(path)}/**")
        run(path, depth + 1)
      else
        if String.ends_with?(path, ".ex") do
          purpose = extract_purpose(path)
          IO.puts("#{indent}- **File: #{Path.basename(path)}** (`#{Path.relative_to(path, "lib")}`) - Purpose: #{purpose}")
        end
      end
    end)
  end

  defp extract_purpose(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/@moduledoc """(.*?)"""/s, content) do
          [_, doc] -> String.trim(String.replace(doc, ~r/\s+/, " "))
          _ -> "Not documented."
        end
      _ -> "Could not read."
    end
  end
end

IO.puts("# ProCoder Recursive Architecture Breakdown\n")
ProCoder.FullAnalyzer.run("lib/procoder")
