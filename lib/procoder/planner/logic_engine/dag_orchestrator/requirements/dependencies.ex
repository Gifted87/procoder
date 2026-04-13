defmodule ProCoder.Planner.DAG.Requirements.Dependencies do
  @moduledoc """
  Authoritative dependency manifest for the ProCoder DAG Orchestrator.
  Ensures structural integrity and environment compliance for graph-based planning.
  """

  require Logger

  @type version_spec :: String.t()
  @type dep_map :: %{atom() => version_spec()}
  @type spec_map :: %{
    dependencies: dep_map(),
    compatibility_matrix: map(),
    checksum: String.t()
  }

  @doc """
  Returns the pre-computed, immutable dependency specification for the DAG orchestrator.
  """
  @spec get_spec() :: spec_map()
  def get_spec do
    %{
      dependencies: %{
        libgraph: "~> 0.16.0",
        jason: "~> 1.4.0"
      },
      compatibility_matrix: %{
        "elixir_1.15" => ["libgraph_0.16", "jason_1.4"],
        "elixir_1.16" => ["libgraph_0.16", "jason_1.4"]
      },
      # SHA-256 of the current dependency definition
      checksum: "7a22ba2eaae8411e497891a90f4f511b1301786d34a6dcde5a347adc01d68517"
    }
  end

  @doc """
  Verifies the runtime environment against the manifest.
  Raises if dependency discrepancies or tampering are detected.
  """
  @spec validate_environment!() :: :ok
  def validate_environment! do
    spec = get_spec()

    # 1. Integrity Check
    unless verify_checksum(spec) do
      raise "Security Violation: Dependency manifest checksum mismatch."
    end

    # 2. Runtime Dependency Check
    Enum.each(spec.dependencies, fn {dep, _version} ->
      unless Code.ensure_loaded?(dep) do
        raise "Environment Mismatch: Required dependency '#{dep}' not loaded."
      end
    end)

    :telemetry.execute([:procoder, :planner, :dependencies, :validated], %{})
    :ok
  end

  @doc """
  Health check callback for the supervisor tree.
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    try do
      validate_environment!()
    rescue
      e -> {:error, e.message}
    end
  end

  defp verify_checksum(spec) do
    # Internal validation of the manifest integrity
    calculated = :crypto.hash(:sha256, :erlang.term_to_binary(Map.delete(spec, :checksum)))
                 |> Base.encode16(case: :lower)
    
    calculated == spec.checksum
  end
end
