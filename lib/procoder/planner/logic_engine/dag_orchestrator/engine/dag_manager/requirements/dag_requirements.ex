defmodule ProCoder.Planner.DAG.Manager.Requirements do
  @moduledoc """
  The authoritative, immutable source of truth for the DAG orchestration engine's
  environmental and dependency configuration.

  This module enforces system-wide constraints, validates runtime dependencies,
  and provides a secure integrity check mechanism for the ProCoder Planner.
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
  Returns the immutable dependency specification manifest.
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
      # SHA-256 of the dependency map definition
      checksum: "7a22ba2eaae8411e497891a90f4f511b1301786d34a6dcde5a347adc01d68517"
    }
  end

  @doc """
  Acts as a gatekeeper for application startup. Performs recursive validation
  of the environment and dependency integrity. Fails fast if anomalies are detected.
  """
  @spec init!() :: :ok | no_return()
  def init! do
    spec = get_spec()

    # 1. Integrity Check (Fail-Fast)
    unless verify_checksum(spec) do
      Logger.emergency("Security Violation: DAG requirement manifest tampered.")
      raise "Security Violation: Dependency manifest checksum mismatch."
    end

    # 2. Dependency Loading Check
    Enum.each(spec.dependencies, fn {dep, _version} ->
      unless Code.ensure_loaded?(dep) do
        Logger.error("Environment Mismatch: Required dependency '#{dep}' not loaded.")
        raise "Environment Mismatch: Required dependency '#{dep}' not loaded."
      end
    end)

    if :ets.whereis(:telemetry_handler_table) != :undefined do
      :telemetry.execute([:procoder, :planner, :dag_requirements, :initialized], %{})
    end
    :ok
  end

  @doc """
  Public health check interface for the supervisor tree to assess operational readiness.
  """
  @spec health_check() :: :ok | {:error, String.t()}
  def health_check do
    try do
      init!()
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  # --- Private Helpers ---

  defp verify_checksum(spec) do
    # Verify manifest integrity excluding the checksum field itself
    manifest_data = Map.delete(spec, :checksum)
    calculated =
      :crypto.hash(:sha256, :erlang.term_to_binary(manifest_data))
      |> Base.encode16(case: :lower)

    calculated == spec.checksum
  end
end
