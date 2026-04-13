defmodule ProCoder.SDK.MacroDSL.Persistence.Hooks.Requirements.Requirements do
  @moduledoc """
  Mandatory dependency, schema, and environment requirements for the Persistence Macro DSL.
  
  This module serves as the configuration and integrity gatekeeper for all macros
  synthesized for cognitive state persistence (snapshotting, rewinding, and LIFO history).
  It ensures that the host process and supervision tree meet the necessary security
  and fault-tolerance requirements for atomic state synchronization.
  """

  @doc """
  Minimum required dependencies for the Persistence Macro DSL subsystem.
  """
  def required_dependencies do
    [
      {:ecto_sqlite3, "~> 0.13.0"},
      {:jason, "~> 1.4.0"},
      {:telemetry, "~> 1.2.0"}
    ]
  end

  @doc """
  Defines the supported versions for snapshot metadata.
  Used by the snapshot macro to ensure structural compatibility across migrations.
  """
  def supported_versions, do: ["1.0.0"]

  @doc """
  Validates the current runtime environment against the persistence requirements.
  Raises an exception if the infrastructure is not configured for atomic persistence.
  """
  @spec validate_persistence_environment!() :: :ok | no_return()
  def validate_persistence_environment! do
    ensure_dependencies!()
    ensure_repo_configured!()
    :ok
  end

  defp ensure_dependencies! do
    for {app, _} <- required_dependencies() do
      unless Code.ensure_loaded?(app) do
        raise "PersistenceMacroDSL Error: Missing mandatory dependency '#{app}'."
      end
    end
  end

  defp ensure_repo_configured! do
    # Validate that the system Repo is correctly configured for the workspace sandbox
    case Application.get_env(:procoder, ProCoder.Repo) do
      nil ->
        raise "PersistenceMacroDSL Error: ProCoder.Repo is not configured."
      config ->
        if Keyword.get(config, :adapter) != Ecto.Adapters.SQLite3 do
          raise "PersistenceMacroDSL Error: Persistence layer requires Ecto.Adapters.SQLite3."
        end
    end
  end
end
