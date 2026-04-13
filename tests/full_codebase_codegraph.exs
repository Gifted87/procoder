defmodule ProCoder.FullCodebaseCodeGraphTest do
  @moduledoc """
  Performance benchmark for the Native CodeGraph Engine across the entire codebase.
  """
  require Logger

  def run do
    # ProCoder system must be running for CodeGraph NIFs to be available
    IO.puts("--- Native CodeGraph Engine: Enterprise-Scale Benchmark ---")
    
    files = Path.wildcard("lib/**/*.ex")
    total_files = Enum.count(files)
    total_size = Enum.reduce(files, 0, fn f, acc -> acc + File.stat!(f).size end)
    
    IO.puts("Targeting: #{total_files} files (#{total_size} bytes total)")
    
    start_time = System.monotonic_time()
    
    results = Enum.map(files, fn path ->
      case ProCoder.Search.CodeGraphEngine.parse_file(path) do
        {:ok, _ast} -> :ok
        {:error, reason} -> {:error, path, reason}
      end
    end)
    
    end_time = System.monotonic_time()
    elapsed_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)
    
    errors = Enum.filter(results, fn r -> match?({:error, _, _}, r) end)
    
    if Enum.empty?(errors) do
      IO.puts("✅ Success: Parsed #{total_files} files in #{elapsed_ms} ms.")
      IO.puts("Aggregate Processing Speed: #{Float.round(total_size / (elapsed_ms / 1000) / 1024, 2)} KB/s")
    else
      IO.puts("❌ Failures detected in #{Enum.count(errors)} files:")
      Enum.each(errors, fn {:error, path, reason} -> 
        IO.puts("  - #{path}: #{inspect(reason)}")
      end)
    end
  end
end

ProCoder.FullCodebaseCodeGraphTest.run()
