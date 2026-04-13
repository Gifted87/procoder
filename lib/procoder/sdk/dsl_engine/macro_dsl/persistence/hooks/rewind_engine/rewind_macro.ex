defmodule ProCoder.SDK.MacroDSL.Persistence.Hooks.RewindEngine.RewindMacro do
  @moduledoc """
  The 'rewind' macro implementation for the ProCoder Persistence DSL.
  
  Provides a high-level, declarative interface for transactional agent state restoration.
  The macro orchestrates the entire recovery sequence, including:
  1. Context validation (SessionManager check).
  2. History stack retrieval (Repo/MemoryStore).
  3. Hash integrity verification.
  4. Triple-layer atomic rollback (Session suspension, Filesystem revert, Memory rehydration).
  5. Compensation (reversion + supervision restart) on failure.
  """

  defmacro rewind(snapshot_id \\ nil) do
    quote do
      # 1. Boilerplate validation: ensure execution within an agent managed by a SessionManager
      # This check ensures that the caller is a GenServer process initialized with the agent context.
      unless Process.get(:agent_context) do
        raise "Rewind Error: Macro must be executed within a ProCoder agent process context."
      end

      # 2. Macro expansion block
      # Offload the I/O-intensive rollback to a separate background Task process
      Task.start(fn ->
        try do
          target_id = unquote(snapshot_id) || :latest
          
          # A. Suspend Agent Execution
          :gen_statem.cast(self(), :suspend_execution)

          # B. Retrieve and Verify
          snapshot = ProCoder.Repo.get_snapshot!(target_id)
          unless ProCoder.Persistence.History.verify_hash(snapshot.memory_blob, snapshot.integrity_hash) do
            ProCoder.Brain.Client.Telemetry.EventMonitor.emit([:procoder, :rewind, :failure], %{}, %{reason: :hash_mismatch})
            raise "Rewind Error: Cognitive state corruption detected. Hash mismatch in snapshot #{snapshot.snapshot_id}."
          end

          # C. Check version compatibility
          unless ProCoder.SDK.MacroDSL.Persistence.Hooks.Requirements.Requirements.supported_versions() 
                 |> Enum.member?(snapshot.version) do
            raise "Rewind Error: Incompatible snapshot version: #{snapshot.version}."
          end

          # D. Atomic Rollback
          # 1. Filesystem restoration
          case ProCoder.Actuator.FilesystemReverter.pop_stash(snapshot.git_commit) do
            :ok ->
              # 2. Rehydrate memory blob
              state = :erlang.binary_to_term(snapshot.memory_blob)
              :gen_statem.cast(self(), {:rehydrate_state, state})
              :gen_statem.cast(self(), :resume_execution)
            
            {:error, reason} ->
              throw({:rollback_failed, reason})
          end

        rescue
          e ->
            Logger.error("Catastrophic rewind failure: #{Exception.message(e)}")
            ProCoder.Brain.Client.Telemetry.EventMonitor.emit([:procoder, :rewind, :critical_failure], %{}, %{error: inspect(e)})
            
            # E. Compensation block
            ProCoder.Actuator.FilesystemReverter.revert_to_stable!()
            ProCoder.Brain.Core.Supervisor.restart_agent(self())
            
            # Move to quarantine
            ProCoder.Repo.quarantine_corrupted_snapshot!(target_id)
        end
      end)
    end
  end
end
