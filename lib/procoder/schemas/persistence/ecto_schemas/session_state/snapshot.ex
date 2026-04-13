defmodule ProCoder.Persistence.Snapshot do
  @moduledoc """
  Ecto schema for ProCoder state snapshots.
  Used for cognitive persistence and /rewind functionality.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "snapshots" do
    field :snapshot_id, :string
    field :session_id, :binary_id
    field :memory_blob, :binary
    field :integrity_hash, :string

    timestamps()
  end

  @doc """
  Maintains structural integrity for cognitive snapshots.
  """
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:snapshot_id, :session_id, :memory_blob, :integrity_hash])
    |> validate_required([:snapshot_id, :session_id, :memory_blob, :integrity_hash])
    |> foreign_key_constraint(:session_id)
  end
end
