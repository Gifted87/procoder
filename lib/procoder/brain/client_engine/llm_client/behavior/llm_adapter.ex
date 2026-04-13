defmodule ProCoder.Brain.Client.Adapter do
  @moduledoc """
  The `ProCoder.Brain.Client.Adapter` behavior defines the functional contract for
  all AI provider implementations within the ProCoder system.

  This behavior mandates the interface for synchronous request-response interactions
  and asynchronous streaming interactions, ensuring compatibility with the
  `gen_statem` orchestrator and the `Finch`-based HTTP communication layer.
  """

  alias ProCoder.Core.Types.Message

  @type opts :: keyword()
  @type stream_reference :: reference()

  @doc """
  Performs a synchronous, blocking interaction with the LLM provider.
  This is intended for short-form, atomic tasks such as planning,
  verification, or metadata generation.
  """
  @callback chat(context :: list(Message.t()), opts :: opts()) ::
              {:ok, Message.t()} | {:error, term()}

  @doc """
  Initiates an asynchronous stream with the LLM provider.
  Tokens are streamed back to the `caller` PID as they are received via SSE.
  Returns a reference to the stream request to allow for tracking and
  cancellation.
  """
  @callback stream(caller :: pid(), context :: list(Message.t()), opts :: opts()) ::
              {:ok, stream_reference()} | {:error, term()}

  @doc """
  Optional: Provides a mechanism to validate the payload structure before
  sending to the provider. Implementations should check for `salience_score`
  and the existence/structure of `tool_calls`.
  """
  @callback validate_payload(messages :: list(Message.t())) :: :ok | {:error, term()}

  # Default implementation/macro support if needed
  defmacro __using__(_opts) do
    quote do
      @behaviour ProCoder.Brain.Client.Adapter
    end
  end
end
