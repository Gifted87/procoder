defmodule ProCoder.Brain.MemoryStore.Types.AgentMemory do
  @moduledoc "Primary cognitive state container for an agent."
  @derive {Jason.Encoder, only: [:id, :task_graph, :history, :metadata, :version]}
  defstruct id: nil,
            task_graph: nil,
            history: nil,
            metadata: %{},
            version: "1.0.0"

  @type t :: %__MODULE__{
          id: binary(),
          task_graph: term(),
          history: any(), # Set to any() to avoid circularity if needed, or point to full name
          metadata: map(),
          version: String.t()
        }

  defimpl String.Chars do
    def to_string(%{id: id}), do: "AgentMemory(id=#{id})"
  end
end

defmodule ProCoder.Brain.MemoryStore.Types.MemorySegment do
  @moduledoc "A time-bounded, compressible slice of cognitive state."
  @derive {Jason.Encoder, only: [:segment_id, :start_time, :end_time, :summary, :version]}
  defstruct segment_id: nil,
            start_time: nil,
            end_time: nil,
            summary: "",
            version: "1.0.0"

  @type t :: %__MODULE__{
          segment_id: binary(),
          start_time: DateTime.t(),
          end_time: DateTime.t(),
          summary: String.t(),
          version: String.t()
        }

  defimpl String.Chars do
    def to_string(%{segment_id: id}), do: "MemorySegment(id=#{id})"
  end
end

defmodule ProCoder.Brain.MemoryStore.Types.CognitiveSnapshot do
  @moduledoc "Versioned state representation for persistence/rewind functionality."
  @derive {Jason.Encoder, only: [:snapshot_id, :agent_id, :state_data, :version]}
  defstruct snapshot_id: nil,
            agent_id: nil,
            state_data: %{},
            version: "1.0.0"

  @type t :: %__MODULE__{
          snapshot_id: binary(),
          agent_id: binary(),
          state_data: map(),
          version: String.t()
        }

  defimpl String.Chars do
    def to_string(_), do: "CognitiveSnapshot(redacted)"
  end
end

defmodule ProCoder.Brain.MemoryStore.Types.MessageHistory do
  @moduledoc "Sequence-aware collection of interactions with salience ranking."
  @derive {Jason.Encoder, only: [:messages, :version]}
  defstruct messages: [],
            version: "1.0.0"

  @type t :: %__MODULE__{
          messages: list(any()),
          version: String.t()
        }

  defimpl String.Chars do
    def to_string(%{messages: msgs}),
      do: "MessageHistory(count=#{length(msgs)})"
  end
end
