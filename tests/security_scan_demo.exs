defmodule ProCoder.SecurityScanDemo do
  @moduledoc """
  Deploys the CyberSecurityAgent and executes a scan on the core macro file.
  """
  require Logger

  def run do
    target_file = "lib/procoder/sdk/dsl_engine/macro_dsl/agents/agent_macro.ex"
    IO.puts("--- Cyber Security Agent: Vulnerability Scan Demo ---")
    IO.puts("Target: #{target_file}")
    
    # In a real swarm, the SessionManager would spawn the agent as a gen_statem.
    # We will simulate the skill call directly on the synthesized module.
    
    IO.puts("\n[Skill: scan_vulnerabilities]")
    case ProCoder.CyberSecurityAgentDemo.CyberSecurityAgent.scan_vulnerabilities(%{"path" => target_file}) do
      {:ok, msg} -> IO.puts("✅ #{msg}")
      {:warn, msg} -> IO.puts("⚠️ #{msg}")
      {:error, reason} -> IO.puts("❌ #{reason}")
    end

    IO.puts("\n[Skill: analyze_ast]")
    case ProCoder.CyberSecurityAgentDemo.CyberSecurityAgent.analyze_ast(%{"path" => target_file}) do
      {:ok, msg} -> IO.puts("✅ #{msg}")
      {:error, reason} -> IO.puts("❌ #{reason}")
    end
    
    IO.puts("\nScan Complete.")
  end
end

ProCoder.SecurityScanDemo.run()
