defmodule ProCoder.SDK.MacroDSL.Persistence.Interface.PersistenceInterface do
  @moduledoc """
  The declarative interface for ProCoder cognitive persistence.

  Provides high-level macros for managing agent state lifecycle:
  - `persist`: Declarative annotation for automatic asynchronous field tracking.
  - `snapshot`: Manual point-in-time atomic state capture.
  - `rewind`: Coordinated, transactional state and worktree restoration.
  """

  require Logger
  alias ProCoder.SDK.MacroDSL.Persistence.Hooks.Validation.DSLValidator
  alias ProCoder.SDK.MacroDSL.Persistence.Hooks.SnapshotEngine


  @doc """
  Declaratively marks fields for automatic asynchronous persistence.
  Must be used within a GenServer or gen_statem module.
  """
  defmacro persist(fields) when is_list(fields) do
    quote do
      require ProCoder.SDK.MacroDSL.Persistence.PersistMacro
      ProCoder.SDK.MacroDSL.Persistence.PersistMacro.persist(unquote(fields))
    end
  end

  @doc """
  Manually triggers an atomic state snapshot.
  MUST be wrapped in `ProCoder.Repo.transaction_atomic/1`.
  """
  defmacro snapshot(session_id, state_vector, version \\ "1.0.0") do
    quote do
      # Compile-time safety: check for transaction block
      DSLValidator.validate_transaction_context!(__CALLER__)

      # Perform capture via industrial-grade engine
      SnapshotEngine.capture(unquote(session_id), unquote(state_vector), unquote(version))
    end
  end

  @doc """
  Triggers a coordinated rollback of memory state and filesystem worktree.
  Performs integrity verification and triggers system-wide recovery if failure occurs.
  """
  defmacro rewind(snapshot_id \\ nil) do
    quote do
      require ProCoder.SDK.MacroDSL.Persistence.Hooks.RewindEngine.RewindMacro
      ProCoder.SDK.MacroDSL.Persistence.Hooks.RewindEngine.RewindMacro.rewind(unquote(snapshot_id))
    end
  end
end
