
defmodule ProCoder.Analyzer do
  def run(dir) do
    File.ls!(dir)
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.each(fn path ->
      if File.dir?(path) do
        IO.puts("## Directory: #{path}")
        run(path)
      else
        if String.ends_with?(path, ".ex") do
          IO.puts("### File: #{path}")
          case File.read(path) do
            {:ok, content} ->
              case Regex.run(~r/@moduledoc """(.*?)"""/s, content) do
                [_, doc] -> IO.puts("Purpose: #{String.trim(doc)}")
                _ -> IO.puts("Purpose: No @moduledoc found.")
              end
            _ -> IO.puts("Could not read file.")
          end
        end
      end
    end)
  end
end

ProCoder.Analyzer.run("lib/procoder")
