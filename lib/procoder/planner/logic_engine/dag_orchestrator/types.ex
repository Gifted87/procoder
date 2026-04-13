defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Types do
  @moduledoc """
  Foundational data structures for the ProCoder Planner's DAG orchestration engine.
  """

  defmodule TaskNode do
    @derive {Jason.Encoder, only: [:id, :task_type, :payload, :status, :retry_count, :recovery_node_id, :metadata]}
    defstruct id: nil,
              task_type: nil,
              payload: %{},
              status: :pending,
              retry_count: 0,
              recovery_node_id: nil,
              metadata: %{
                created_at: nil,
                transitioned_at: nil,
                duration_ms: 0,
                integrity_hash: nil
              }

    @type status :: :pending | :running | :completed | :failed
    @type t :: %__MODULE__{
            id: String.t() | nil,
            task_type: atom() | nil,
            payload: map(),
            status: status(),
            retry_count: non_neg_integer(),
            recovery_node_id: String.t() | nil,
            metadata: map()
          }
  end

  defmodule GraphState do
    @derive {Jason.Encoder, only: [:session_id, :global_goal, :graph, :node_registry, :history_stack]}
    defstruct session_id: nil,
              global_goal: "",
              graph: nil,
              node_registry: %{},
              history_stack: []

    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            global_goal: String.t(),
            graph: Graph.t() | nil,
            node_registry: map(),
            history_stack: list(term())
          }
  end

  @doc """
  Validates input map against the TaskNode structure requirements.
  """
  @spec from_map(map()) :: {:ok, TaskNode.t()} | {:error, term()}
  def from_map(attrs) do
    id = attrs[:id] || attrs["id"]
    type = attrs[:task_type] || attrs["task_type"]

    if id && type do
      atom_type = if is_binary(type), do: String.to_existing_atom(type), else: type
      # We create a normalized map for struct()
      normalized = %{
        id: id,
        task_type: atom_type,
        payload: attrs[:payload] || attrs["payload"] || %{},
        metadata: attrs[:metadata] || attrs["metadata"] || %{}
      }
      {:ok, struct(TaskNode, normalized)}
    else
      {:error, :missing_required_fields}
    end
  rescue
    _ -> {:error, :invalid_type_conversion}
  end

  @doc """
  Creates a new GraphState container.
  """
  @spec new_state(String.t(), String.t()) :: GraphState.t()
  def new_state(session_id, global_goal \\ "") do
    %GraphState{
      session_id: session_id,
      global_goal: global_goal,
      graph: Graph.new(type: :directed),
      node_registry: %{},
      history_stack: []
    }
  end
end
