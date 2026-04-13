defmodule ProCoder.Brain.Client.HTTPPool.Manager do
  @moduledoc """
  A static manager for LLM HTTP pools.
  Returns the global Finch pool name.
  """

  @doc """
  Checks out a connection pool.
  Returns {:ok, :procoder_finch}.
  """
  def checkout(_endpoint_id) do
    {:ok, :procoder_finch}
  end

  # Dummy start_link to satisfy supervisor if still listed (though we removed it)
  def start_link(_opts) do
    {:ok, spawn(fn -> :timer.sleep(:infinity) end)}
  end
end
