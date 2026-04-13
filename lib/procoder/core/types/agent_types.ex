defmodule ProCoder.Core.Types.AgentContext do
  @moduledoc """
  Primary state container for an individual ProCoder worker process.
  """
  @derive {Jason.Encoder, only: [:id, :status, :workspace_root, :task_graph, :created_at, :metadata, :version]}
  defstruct id: nil,
            status: :idle,
            workspace_root: nil,
            task_graph: nil,
            created_at: nil,
            metadata: %{},
            version: "1.0.0"

  @type agent_status :: :idle | :discovery | :planning | :synthesis | :execution | :verifying
  @type t :: %__MODULE__{
    id: String.t() | nil,
    status: agent_status(),
    workspace_root: Path.t() | nil,
    task_graph: any(),
    created_at: DateTime.t() | nil,
    metadata: map(),
    version: String.t()
  }

  defimpl String.Chars do
    def to_string(%ProCoder.Core.Types.AgentContext{id: id}), do: "AgentContext(id=#{id})"
  end
end

defmodule ProCoder.Core.Types.Message do
  @moduledoc """
  Standardized communication structure between the PromptEngine and LLM API client.
  """
  @derive {Jason.Encoder, only: [:role, :content, :salience_score, :tool_calls, :timestamp]}
  defstruct role: :user,
            content: "",
            salience_score: 0.0,
            tool_calls: nil,
            timestamp: nil

  @type role :: :system | :user | :assistant
  @type t :: %__MODULE__{
    role: role(),
    content: String.t(),
    salience_score: float(),
    tool_calls: list(map()) | map() | nil,
    timestamp: DateTime.t() | nil
  }

  defimpl String.Chars do
    def to_string(_), do: "Message(role=redacted)"
  end
end

defmodule ProCoder.Core.Types.SearchResult do
  @moduledoc """
  Result container for the Gradient of Precision search cascade.
  """
  @derive {Jason.Encoder, only: [:source, :content, :score, :metadata]}
  defstruct source: :lsp,
            content: "",
            score: 0.0,
            metadata: %{}

  @type source :: :lsp | :text_engine | :vector_store
  @type t :: %__MODULE__{
    source: source(),
    content: String.t(),
    score: float(),
    metadata: map()
  }

  defimpl String.Chars do
    def to_string(%ProCoder.Core.Types.SearchResult{source: source, score: score}) do
      "SearchResult(source=#{source}, score=#{score})"
    end
  end
end
