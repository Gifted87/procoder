defmodule ProCoder.Tests.RewindDemo do
  @moduledoc """
  Demonstrates the /rewind (Time Travel) mechanism.
  Validates that cognitive state can be atomically rolled back.
  """
  require Logger
  alias ProCoder.Core.AgentFSM
  alias ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine
  
  def run_test do
    IO.puts("--- Rewind (Time Travel) Demo: Starting ---")
    session_id = "rewind_test_session_#{:erlang.unique_integer([:positive])}"
    worktree = "/tmp/procoder_worktrees/rewind_test"
    File.mkdir_p!(worktree)

    # 1. Start History Engine (Hot Stack)
    {:ok, _} = HistoryStackEngine.start_link(session_id: session_id)
    
    # 2. Start AgentFSM
    {:ok, agent_pid} = AgentFSM.start_link(session_id: session_id, worktree_root: worktree, goal: "Initial Goal")
    Process.sleep(100)

    # 3. Trigger first action
    IO.puts("Spawning agent and setting Goal 1...")
    GenServer.cast(agent_pid, {:plan, "Goal 1: Setup project"})
    Process.sleep(500)
    
    # Capture state after Goal 1
    {_state_name, data1} = :sys.get_state(agent_pid)
    IO.puts("History Length after Goal 1: #{length(data1.history)}")

    # 4. Trigger second action
    IO.puts("Updating Goal to Goal 2...")
    GenServer.cast(agent_pid, {:plan, "Goal 2: Break things"})
    Process.sleep(500)
    
    {_state_name, data2} = :sys.get_state(agent_pid)
    IO.puts("History Length after Goal 2: #{length(data2.history)}")

    # Verify expansion
    if length(data2.history) <= length(data1.history) do
      IO.puts("❌ Test Initialization Failed: History did not advance.")
      return_error()
    end

    # 5. Perform Rewind (Pop latest snapshot and restore)
    IO.puts("Performing Atomic Rewind...")
    AgentFSM.rewind(agent_pid)
    Process.sleep(500)
    
    {_state_name, data_final} = :sys.get_state(agent_pid)
    IO.puts("History Length after Rewind: #{length(data_final.history)}")
    
    if length(data_final.history) == length(data1.history) do
      IO.puts("✅ Test Passed: Agent cognitive memory successfully rolled back to synced state.")
    else
      IO.puts("❌ Test Failed: Rewind did not restore expected history length.")
      IO.puts("Expected: #{length(data1.history)}, Got: #{length(data_final.history)}")
    end
  end

  defp return_error, do: System.halt(1)
end

ProCoder.Tests.RewindDemo.run_test()
