defmodule ProCoder.SecureAgentDemo do
  @moduledoc """
  A real-life demonstration of a valid ProCoder Agent.
  This module defines a secure agent using the ProCoder DSL macros.
  """
  use ProCoder.SDK.MacroDSL.Agents.AgentMacro

  defagent SecureAgent do
    @moduledoc "A secure and documented agent."
    
    defskill greet do
      IO.puts("Hello from the Secure Agent!")
    end

    defskill get_config do
      # Allowed system call
      System.get_env("PROCODER_MODE")
    end
  end
end
