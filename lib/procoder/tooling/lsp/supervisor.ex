defmodule ProCoder.Tooling.LSP.Supervisor do
  @moduledoc """
  A DynamicSupervisor for managing individual Language Server processes.
  LSPs are started on-demand for specific worktrees.
  """

  use DynamicSupervisor
  require Logger

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Spawns a new LSP server for a session.
  """
  def start_lsp_server(_session_id, _worktree_root, _language) do
    # Placeholder for starting a specific LSP process
    # child_spec = {ProCoder.Tooling.LSP.Server, [session_id: session_id, ...]}
    # DynamicSupervisor.start_child(__MODULE__, child_spec)
    {:ok, self()} # Temporary
  end
end
