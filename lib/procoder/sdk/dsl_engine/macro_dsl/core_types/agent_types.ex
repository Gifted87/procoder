defmodule ProCoder.SDK.MacroDSL.CoreTypes.AgentTypes do
  @moduledoc """
  Foundational data structures for the ProCoder SDK Macro DSL.

  This module defines the structural primitives required for defining custom,
  headless autonomous agents. It enforces cognitive persistence via metadata
  tracking and integrates with the core gen_statem lifecycle requirements.
  """

  @derive {Jason.Encoder, only: [:id, :status, :metadata, :version, :created_at, :security_header]}
  defstruct id: nil,
            status: :idle,
            metadata: %{},
            version: "1.0.0",
            created_at: nil,
            security_header: nil

  @type agent_status :: :idle | :planning | :thinking | :tool_execution | :verifying

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: agent_status(),
          metadata: map(),
          version: String.t(),
          created_at: DateTime.t() | nil,
          security_header: ProCoder.SDK.MacroDSL.CoreTypes.SecurityHeader.t() | nil
        }

  @doc """
  Validates if the provided status is a valid lifecycle state.
  """
  @spec valid_status?(atom()) :: boolean()
  def valid_status?(status) when status in [:idle, :planning, :thinking, :tool_execution, :verifying],
    do: true

  def valid_status?(_), do: false
end

defmodule ProCoder.SDK.MacroDSL.CoreTypes.SecurityHeader do
  @moduledoc """
  Audit trail structure required for all agent instances.
  Tracks identity, origin, and authorization metadata.
  """
  @derive {Jason.Encoder, only: [:agent_identity, :origin_node, :policy_version, :timestamp]}
  defstruct agent_identity: nil,
            origin_node: nil,
            policy_version: "1.0.0",
            timestamp: nil

  @type t :: %__MODULE__{
          agent_identity: String.t(),
          origin_node: atom() | String.t(),
          policy_version: String.t(),
          timestamp: DateTime.t()
        }
end

defmodule ProCoder.SDK.MacroDSL.CoreTypes.TaskState do
  @moduledoc """
  Represents the granular state of an agent's current task execution.
  """
  @derive {Jason.Encoder, only: [:task_id, :goal, :steps, :status, :metadata]}
  defstruct task_id: nil,
            goal: "",
            steps: [],
            status: :pending,
            metadata: %{}

  @type t :: %__MODULE__{
          task_id: String.t(),
          goal: String.t(),
          steps: list(map()),
          status: :pending | :running | :completed | :failed,
          metadata: map()
        }
end

defmodule ProCoder.SDK.MacroDSL.CoreTypes.SkillExecution do
  @moduledoc """
  Encapsulates data for a procedural skill execution.
  Tags sensitive parameters for automatic redaction.
  """
  @derive {Jason.Encoder, only: [:skill_name, :params, :execution_id, :status]}
  defstruct skill_name: nil,
            params: %{},
            execution_id: nil,
            status: :started

  @type t :: %__MODULE__{
          skill_name: String.t(),
          params: map(),
          execution_id: String.t(),
          status: :started | :finished | :failed
        }

  @doc """
  Determines if a parameter key is considered sensitive.
  """
  @spec sensitive?(String.t() | atom()) :: boolean()
  def sensitive?(key) when key in [:api_key, :password, :token, "api_key", "password", "token"],
    do: true

  def sensitive?(_), do: false

  @doc """
  Redacts sensitive fields in the execution parameters map.
  """
  @spec redact_params(map()) :: map()
  def redact_params(params) when is_map(params) do
    Enum.reduce(params, %{}, fn {k, v}, acc ->
      if sensitive?(k), do: Map.put(acc, k, "[REDACTED]"), else: Map.put(acc, k, v)
    end)
  end
end
