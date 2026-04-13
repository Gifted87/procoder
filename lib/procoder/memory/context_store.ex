defmodule ProCoder.Memory.ContextStore do
  @moduledoc """
  Manages ephemeral memory using ETS (Erlang Term Storage).
  Provides public read access and protected write access for session context.
  """
  require Logger

  @doc """
  Injects a file's content into the session's context ETS table.
  """
  def inject(session_id, path) do
    table = ensure_table(session_id)
    case File.read(path) do
      {:ok, content} ->
        :ets.insert(table, {path, content, DateTime.utc_now()})
        Logger.info("Injected context from #{path} into #{session_id}")
        :ok
      {:error, reason} ->
        Logger.error("Failed to inject context from #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Evicts a file from the session's context ETS table.
  """
  def evict(session_id, path) do
    table = ensure_table(session_id)
    :ets.delete(table, path)
    Logger.info("Evicted context for #{path} from #{session_id}")
    :ok
  end

  defp ensure_table(session_id) do
    name = table_name(session_id)
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:set, :public, :named_table, {:read_concurrency, true}])
      _ -> name
    end
  end

  defp table_name(session_id), do: String.to_atom("cache_#{session_id}")
end
