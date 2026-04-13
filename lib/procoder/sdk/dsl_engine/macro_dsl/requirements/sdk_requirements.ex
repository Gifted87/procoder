defmodule ProCoder.SDK.DSL.Requirements.SDKRequirements do
  @moduledoc """
  Mandatory dependency and environment requirements for the ProCoder Developer SDK.
  
  This module acts as the integrity validator for agent-defined macros, ensuring that any
  code synthesized via the SDK DSL conforms to the system's architectural constraints
  (OTP 26+, Elixir 1.15+, and secure infrastructure).
  """

  @doc """
  Minimum required environment versions.
  """
  def min_elixir_version, do: "1.15.0"
  def min_otp_version, do: "26.0"

  @doc """
  Mandatory SDK dependencies required for runtime execution of agents.
  """
  def required_dependencies do
    [
      {:finch, "~> 0.17.0"},
      {:jason, "~> 1.4.0"},
      {:ecto_sqlite3, "~> 0.13.0"}
    ]
  end

  @doc """
  Validates that the current environment meets the minimum requirements for SDK usage.
  Raises an exception if dependencies or versions are not met.
  """
  @spec validate_environment!() :: :ok | no_return()
  def validate_environment! do
    ensure_elixir_version!()
    ensure_otp_version!()
    ensure_dependencies!()
    :ok
  end

  defp ensure_elixir_version! do
    unless Version.match?(System.version(), ">= #{min_elixir_version()}") do
      raise "ProCoder SDK requires Elixir >= #{min_elixir_version()}. Found: #{System.version()}"
    end
  end

  defp ensure_otp_version! do
    otp_version = :erlang.system_info(:otp_release) |> List.to_string()
    
    # OTP 26 returns '26'
    unless String.to_integer(otp_version) >= String.to_integer(min_otp_version()) do
      raise "ProCoder SDK requires OTP >= #{min_otp_version()}. Found: #{otp_version}"
    end
  end

  defp ensure_dependencies! do
    for {app, _} <- required_dependencies() do
      unless Code.ensure_loaded?(app) do
        raise "ProCoder SDK dependency failure: Application '#{app}' not found."
      end
    end
  end
end
