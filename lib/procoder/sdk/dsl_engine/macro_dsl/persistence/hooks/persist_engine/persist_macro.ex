defmodule ProCoder.SDK.MacroDSL.Persistence.PersistMacro do
  @moduledoc """
  Defines the `persist` macro for declarative state persistence in ProCoder agents.
  
  This macro automatically injects the necessary logic for field registration,
  lifecycle interception (via `handle_event` or state functions), and asynchronous
  persistence dispatch, ensuring zero-cost cognitive persistence.
  """

  require Logger
  alias ProCoder.SDK.DSL.Validation.DSLValidator

  defmacro persist(fields) when is_list(fields) do
    quote bind_quoted: [fields: fields] do
      # 1. Compile-time lifecycle validation
      DSLValidator.validate_lifecycle!(__CALLER__)

      # 2. Inject field registration metadata
      @doc """
      Returns the list of fields tracked by the persistence engine for this agent.
      """
      def __persistence_fields__, do: unquote(fields)

      # 3. Lifecycle Interception logic
      # Support GenServer (handle_event/3) and gen_statem (handle_event/4)
      if Module.defines?(__MODULE__, {:handle_event, 4}) do
        @impl true
        def handle_event(event_type, event_content, state, data) do
          # Trigger asynchronous persistence capture before processing
          spawn(fn -> 
            capture_and_persist(data)
          end)

          super(event_type, event_content, state, data)
        end
      else
        @impl true
        def handle_call(req, from, data) do
          spawn(fn -> capture_and_persist(data) end)
          super(req, from, data)
        end
      end

      # 4. Termination Hook for final snapshot
      @impl true
      def terminate(reason, state, data) do
        Logger.info("Persisting final snapshot for agent during termination: #{inspect(reason)}")
        capture_and_persist(data, final: true)
        if function_exported?(super_module(), :terminate, 3), do: super(reason, state, data)
      end

      # 5. Internal Persistence Engine
      defp capture_and_persist(data, opts \\ []) do
        fields = __persistence_fields__()
        
        # Extract fields
        snapshot = 
          fields 
          |> Enum.reduce(%{}, fn field, acc -> 
            Map.put(acc, field, Map.get(data, field)) 
          end)
          |> Map.put(:version, "1.0.0")
          |> Map.put(:metadata, %{
            timestamp: DateTime.utc_now(),
            pid: inspect(self())
          })

        # Redact and Dispatch
        redacted = ProCoder.Brain.Client.Telemetry.EventMonitor.redact_metadata(snapshot)
        
        # Asynchronous fire-and-forget to SessionManager
        GenServer.cast(ProCoder.SessionManager, {:persist_state, data.id, data.session_id, redacted})
      end
    end
  end
end
