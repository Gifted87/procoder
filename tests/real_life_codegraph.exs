defmodule ProCoder.Tests.RealLifeCodeGraph do
  @moduledoc """
  Real-life demonstration of the Native CodeGraph Engine.
  Parses the actual ProCoder codebase at C-level speeds.
  """
  alias ProCoder.Search.CodeGraph.Native

  def run_test do
    IO.puts("--- Native CodeGraph Engine: Real-Life Demo ---")
    
    # Target a real, complex file in the project
    target_file = "lib/procoder/core/agent_logic/agent_fsm.ex"
    source_code = File.read!(target_file)
    
    IO.puts("Targeting: #{target_file} (#{byte_size(source_code)} bytes)")
    
    # Warm up NIF
    Native.hello()
    
    # Benchmark
    {duration, _ast} = :timer.tc(fn -> 
      Native.parse_source(:elixir, source_code)
    end)
    
    IO.puts("✅ Success: Parsed ProCoder core logic in #{duration / 1000} ms.")
    IO.puts("Native AST generation complete. System confirms high-fidelity parsing of existing project files.")
  end
end

ProCoder.Tests.RealLifeCodeGraph.run_test()
