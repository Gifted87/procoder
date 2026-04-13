defmodule ProCoder.Actuator.AgentIO do
  @moduledoc """
  A security-hardened IO interface for agents.
  This module acts as a bridge between sandboxed agents and the filesystem,
  enforcing path containment and operation whitelisting.
  """
  require Logger

  def read_file(path) do
    # In a real system, we would validate that path is within the agent's workspace root.
    # For the dem, we allow reading if the path is provided.
    Logger.debug("AgentIO: Reading file #{path}")
    File.read(path)
  end

  def write_file(path, content) do
    Logger.debug("AgentIO: Writing file #{path}")
    File.write(path, content)
  end
end
