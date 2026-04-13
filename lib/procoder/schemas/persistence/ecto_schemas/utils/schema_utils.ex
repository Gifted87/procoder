defmodule ProCoder.Persistence.Schema.Utils do
  @moduledoc """
  Standardized utility library for the ProCoder persistence layer.
  Provides primitives for cryptographic integrity, UUID generation, and changeset validation.
  """

  import Ecto.Changeset

  @doc """
  Generates a unique, globally consistent Ecto UUID.
  Used for primary and foreign key fields across the ProCoder system.

  ## Example
      iex> ProCoder.Persistence.Schema.Utils.generate_id()
      "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
  """
  def generate_id, do: Ecto.UUID.generate()

  @doc """
  Computes a normalized SHA-256 hash for AST node content verification.
  Leverages BEAM's :crypto library for high performance.

  ## Example
      iex> ProCoder.Persistence.Schema.Utils.hash_content("defmodule Hello do ... end")
      "..."
  """
  def hash_content(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc """
  Standardized validator for required schema fields.
  Accepts a changeset and a list of atom field names.
  """
  def validate_required_fields(changeset, fields) when is_list(fields) do
    validate_required(changeset, fields)
  end

  @doc """
  Validates that a field matches an expected Ecto type.
  """
  def validate_type(changeset, field, type) do
    validate_change(changeset, field, fn _, value ->
      case type do
        :string when is_binary(value) -> []
        :integer when is_integer(value) -> []
        :map when is_map(value) -> []
        _ -> [{field, "is not a valid #{type}"}]
      end
    end)
  end

  @doc """
  Validates ephemeral state snapshots stored in JSONB fields.
  Ensures the snapshot map contains the necessary structural keys for rewinding.
  """
  def validate_snapshot(changeset) do
    validate_change(changeset, :snapshot, fn :snapshot, snapshot ->
      if is_map(snapshot) and Map.has_key?(snapshot, "version") do
        []
      else
        [snapshot: "must be a map containing a 'version' key"]
      end
    end)
  end

  @doc """
  Generic helper for mapping AST node metadata to internal schema structures.
  Should be implemented or delegated to by specific schema entities.
  """
  def from_ast(ast_node) when is_map(ast_node) do
    # Implementation depends on the structure of the AST input,
    # mapping standardized node metadata (line, column, content) to fields.
    {:ok, ast_node}
  end
  def from_ast(_), do: {:error, :invalid_ast_node}
end
