defmodule ProCoder.Schemas.Persistence.EctoSchemas.AstEdge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ast_edges" do
    field :source_node_id, :binary_id
    field :target_node_id, :binary_id
    field :label, :string

    timestamps()
  end

  def changeset(ast_edge, attrs) do
    ast_edge
    |> cast(attrs, [:source_node_id, :target_node_id, :label])
    |> validate_required([:source_node_id, :target_node_id])
  end
end
