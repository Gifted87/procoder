defmodule ProCoder.Persistence.TaskNode do
  @moduledoc """
  Ecto schema for TaskNode persistence within the ProCoder DAG structure.
  
  Facilitates task scheduling, dependency tracking, and failure recovery through
  self-referential recovery node linkages. Designed for high-concurrency environments
  using binary UUIDs and JSONB-compatible payload storage.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import ProCoder.Persistence.Schema.Utils, only: [validate_required_fields: 2, validate_type: 3]
  alias ProCoder.Persistence.Session


  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_nodes" do
    field :task_type, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :retry_count, :integer, default: 0

    belongs_to :session, Session, foreign_key: :session_id
    belongs_to :recovery_node, ProCoder.Persistence.TaskNode, foreign_key: :recovery_node_id

    timestamps()
  end

  @valid_statuses ~w(pending running completed failed)

  @doc """
  Changeset for TaskNode validation and casting.
  Enforces strict type checks, status constraints, and session referential integrity.
  """
  def changeset(task_node, attrs) do
    task_node
    |> cast(attrs, [:session_id, :task_type, :payload, :status, :retry_count, :recovery_node_id])
    |> validate_required_fields([:session_id, :task_type, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> validate_type(:payload, :map)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:recovery_node_id)
  end

  @doc """
  Maps raw task data to a compliant schema changeset.
  
  Used by the Planner to persist decomposed DAG segments.
  """
  def from_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end
end
