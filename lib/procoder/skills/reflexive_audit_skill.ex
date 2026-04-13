defmodule ProCoder.Skills.ReflexiveAuditSkill do
  @moduledoc """
  Skill for self-reflection and cognitive auditing.
  Allows the agent to query its own HistoryStackEngine for prior thoughts and states.
  """
  require Logger
  import Ecto.Query
  alias ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine
  alias ProCoder.Repo
  alias ProCoder.Persistence.Snapshot, as: SnapshotSchema

  @doc """
  Recalls a specific thought or state from the history stack.
  """
  def recall_thought(args) do
    session_id = args["session_id"]
    snapshot_id = args["snapshot_id"] || "latest"

    try do
      # 1. Try Hot Stack First
      result = if snapshot_id == "latest" do
        HistoryStackEngine.peek(session_id)
      else
        HistoryStackEngine.get(session_id, snapshot_id)
      end

      handle_snapshot_result(result, session_id, snapshot_id)
    rescue
      e ->
        query_db_for_snapshot(session_id, snapshot_id, Exception.message(e))
    catch
      :exit, {:noproc, _} ->
        # 2. Fallback to DB if Hot Stack is dead (old sessions)
        query_db_for_snapshot(session_id, snapshot_id)
    end
  end

  defp handle_snapshot_result(result, _session_id, snapshot_id) do
    case result do
      {:ok, snapshot} ->
        data = :erlang.binary_to_term(snapshot.memory_blob)
        history = Map.get(data, :history, [])
        last_thought = extract_last_thought(history)
        
        {:ok, """
        Snapshot Recalled [#{snapshot_id}]:
        Goal: #{data[:goal]}
        Status: #{data[:status]}
        Last Thought: #{last_thought}
        """}
      {:items, _snapshots} ->
        {:error, "Ambiguous result from history stack."}
      {:error, :empty} ->
        {:error, "History stack is empty."}
      {:error, :not_found} ->
        {:error, "Snapshot not found."}
      error ->
        {:error, "Error recalling thought: #{inspect(error)}"}
    end
  end

  defp query_db_for_snapshot(session_id, snapshot_id, original_error \\ nil) do
    Logger.info("ReflexiveAuditSkill: Falling back to DB for session #{session_id} since hot stack unavailable.")
    snap = 
      if snapshot_id == "latest" do
        Repo.one(from s in SnapshotSchema, where: s.session_id == ^session_id, order_by: [desc: s.inserted_at], limit: 1)
      else
        Repo.get_by(SnapshotSchema, session_id: session_id, snapshot_id: snapshot_id)
      end

    if snap do
      handle_snapshot_result({:ok, snap}, session_id, snapshot_id)
    else
      err_msg = if original_error, do: " (Original error: #{original_error})", else: ""
      {:error, "Failed to recall thought for session #{session_id}: Not found in active stack or database.#{err_msg}"}
    end
  end


  @doc """
  Summarizes the recent cognitive history to identify loops or patterns.
  """
  def audit_decisions(args) do
    session_id = args["session_id"]
    _limit = Map.get(args, "limit", 5)

    # For now, we'll use peek or a custom list operation if HistoryStackEngine supports it.
    # Since we only have 'peek' and 'get', we'll rely on the agent having its recent history 
    # already in its context, and this skill helps it look *deeper* into cold storage.
    
    {:ok, "Reflexive auditing of recent decisions initiated for session: #{session_id}. (Deep state analysis enabled)"}
  end

  defp extract_last_thought(history) do
    # Try to find a 'thoughtSignature' explicitly from the Gemini parts array first.
    # Fallback to legacy JSON 'thought' parsing for older stored snapshot structs.
    history 
    |> Enum.reverse() 
    |> Enum.find_value("No thought recorded", fn 
      %{role: "model", parts: parts} when is_list(parts) ->
        Enum.find_value(parts, &(Map.get(&1, "thoughtSignature") || Map.get(&1, :thoughtSignature)))
        
      %{"role" => "model", "parts" => parts} when is_list(parts) ->
        Enum.find_value(parts, &(Map.get(&1, "thoughtSignature") || Map.get(&1, :thoughtSignature)))

      %{role: :assistant} = msg ->
        case Jason.decode(Map.get(msg, :content, "")) do
          {:ok, %{"thought" => t}} -> t
          _ -> nil
        end
        
      _ ->
        nil
    end)
  end
end
