defmodule ProCoder.Persistence.CodeGraphNode do
  @moduledoc """
  Ecto schema representing an AST node within the ProCoder CodeGraph.
  Stores structural metadata, source location, and integrity hashes.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import ProCoder.Persistence.Schema.Utils, only: [validate_type: 3]
  alias ProCoder.Persistence.Schema.Utils

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "code_graph_nodes" do
    field :node_type, :string
    field :source_range, :map
    field :content_hash, :string
    field :file_path, :string

    timestamps(inserted_at: :inserted_at, updated_at: :updated_at)
  end

  @doc """
  Creates a changeset for a CodeGraphNode.
  Enforces mandatory fields and validates the structure of the source_range map.
  """
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:node_type, :source_range, :content_hash, :file_path])
    |> validate_required([:node_type, :source_range, :content_hash, :file_path])
    |> validate_source_range()
    |> validate_type(:node_type, :string)
    |> validate_type(:content_hash, :string)
    |> validate_type(:file_path, :string)
  end

  @doc """
  Maps a raw Tree-sitter node map to a database-compatible changeset.
  Calculates the content_hash using the persistence utility.
  """
  def from_ast(ast_node) do
    case validate_ast_input(ast_node) do
      {:ok, data} ->
        content = Map.get(data, "content", "")
        hash = Utils.hash_content(content)

        {:ok,
         %{
           node_type: Map.get(data, "node_type"),
           source_range: Map.get(data, "source_range"),
           content_hash: hash,
           file_path: Map.get(data, "file_path")
         }}

      error ->
        error
    end
  end

  defp validate_ast_input(node) do
    required = ["node_type", "source_range", "file_path", "content"]

    if Enum.all?(required, &Map.has_key?(node, &1)) do
      {:ok, node}
    else
      {:error, :invalid_ast_node}
    end
  end

  defp validate_source_range(changeset) do
    validate_change(changeset, :source_range, fn :source_range, range ->
      required_keys = ["start_line", "start_col", "end_line", "end_col"]

      if is_map(range) and Enum.all?(required_keys, &Map.has_key?(range, &1)) do
        []
      else
        [source_range: "must be a map containing: #{Enum.join(required_keys, ", ")}"]
      end
    end)
  end
end
