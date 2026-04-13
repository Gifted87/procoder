defmodule ProCoder.Persistence.Session do
  @moduledoc """
  Ecto schema representing the persistent state of an autonomous agent session.
  
  Provides fault-tolerant state recovery through context snapshots and ensures
  filesystem isolation by pinning agent worktrees to specific, validated directories.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import ProCoder.Persistence.Schema.Utils, only: [validate_required_fields: 2]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :status, :string, default: "idle"
    field :context_snapshot, :map, default: %{}
    field :git_worktree_path, :string

    timestamps()
  end

  @valid_statuses ~w(idle planning thinking tool_execution verifying)

  @doc """
  Authoritative interface for session state transitions and validation.
  
  Enforces FSM constraints, structure of context snapshots, and security-critical
  validation of git_worktree_path.
  """
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:status, :context_snapshot, :git_worktree_path])
    |> validate_required_fields([:status, :git_worktree_path])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_path_containment(:git_worktree_path)
    |> validate_snapshot_structure()
  end

  defp validate_path_containment(changeset, field) do
    validate_change(changeset, field, fn field, path ->
      root = Application.get_env(:procoder, ProCoder.SessionManager)[:worktree_root]
      
      cond do
        is_nil(root) ->
          [{field, "configuration error: worktree_root not defined"}]
        
        not String.starts_with?(Path.expand(path), Path.expand(root)) ->
          [{field, "path outside authorized sandbox: #{root}"}]
        
        true ->
          []
      end
    end)
  end

  defp validate_snapshot_structure(changeset) do
    validate_change(changeset, :context_snapshot, fn field, snapshot ->
      if is_map(snapshot) do
        []
      else
        [{field, "must be a JSON serializable map"}]
      end
    end)
  end
end
