defmodule ProCoder.Core.HistoryManagement.RewindManager.MemorySnapshotManager do
  @moduledoc """
  The MemorySnapshotManager provides high-performance, secure serialization and 
  de-serialization for the ProCoder cognitive persistence layer. 
  
  It performs mandatory PII redaction and structural validation to ensure 
  agent state integrity during /rewind operations.
  """

  alias ProCoder.Core.Types.AgentContext

  @sensitive_keys [:api_key, :password, :token, :secret]

  @doc """
  Serializes an AgentContext into a compressed binary blob.
  Applies mandatory PII redaction before serialization.
  """
  @spec serialize_state(AgentContext.t()) :: {:ok, binary()} | {:error, term()}
  def serialize_state(%AgentContext{} = context) do
    try do
      sanitized = redact_memory(context)
      binary = :erlang.term_to_binary(sanitized, [:compressed])
      {:ok, binary}
    rescue
      e -> {:error, :serialization_failed, Exception.message(e)}
    end
  end

  @doc """
  Deserializes a binary blob into an AgentContext struct.
  Performs structural validation post-deserialization.
  """
  @spec deserialize_state(binary()) :: {:ok, AgentContext.t()} | {:error, :incompatible_state}
  def deserialize_state(binary) when is_binary(binary) do
    try do
      term = :erlang.binary_to_term(binary)
      
      if valid_context?(term) do
        {:ok, term}
      else
        {:error, :incompatible_state}
      end
    rescue
      _ -> {:error, :incompatible_state}
    end
  end
  def deserialize_state(_), do: {:error, :incompatible_state}

  # --- Internal Logic ---

  defp redact_memory(%AgentContext{metadata: metadata} = context) do
    redacted_metadata =
      metadata
      |> Enum.reject(fn {k, _v} -> k in @sensitive_keys end)
      |> Map.new()

    %{context | metadata: redacted_metadata}
  end

  defp valid_context?(%AgentContext{id: id, status: status}) when not is_nil(id) and not is_nil(status) do
    true
  end
  defp valid_context?(_), do: false
end
