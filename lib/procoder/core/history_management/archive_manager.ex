defmodule ProCoder.Core.HistoryManagement.ArchiveManager do
  @moduledoc """
  Manages the persistence and retrieval of conversation archives as JSON files.
  """
  require Logger

  @archive_dir ".archives"

  @doc "Archives a session's history and metadata to the 'archives' directory."
  def archive_session(session_id, history, metadata \\ %{}) do
    try do
      File.mkdir_p!(@archive_dir)
      title = metadata[:goal] || "Untitled Conversation"
      timestamp = DateTime.to_iso8601(DateTime.utc_now())
      
      archive_data = %{
        "id" => session_id,
        "title" => title,
        "timestamp" => timestamp,
        "history" => history,
        "metadata" => metadata
      }

      path = Path.join(@archive_dir, "#{session_id}.json")
      File.write!(path, Jason.encode!(archive_data, pretty: true))
      Logger.info("[ARCHIVE] Session #{session_id} archived to #{path}")
      :ok
    rescue
      e -> 
        Logger.error("[ARCHIVE] Failed to archive session #{session_id}: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc "Archives the current session by pulling its latest state from the HistoryStackEngine."
  def archive_current_session(session_id) do
    # Check if the history stack process is alive before calling peek
    via = {:via, Registry, {ProCoder.Registry, "history_stack_#{session_id}"}}
    
    if GenServer.whereis(via) do
      case ProCoder.Core.HistoryManagement.RewindManager.StackEngine.HistoryStackEngine.peek(session_id) do
        {:ok, snap} ->
          data = :erlang.binary_to_term(snap.memory_blob)
          archive_session(session_id, data.history, %{goal: data.goal})
        _ -> 
          Logger.warn("[ARCHIVE] No snapshot found for #{session_id} to archive.")
          {:error, :no_snapshot}
      end
    else
      Logger.warn("[ARCHIVE] History stack for #{session_id} is not active. Skipping.")
      {:error, :no_process}
    end
  end

  @doc "Lists all archived conversations with their metadata."
  def list_archives do
    if File.dir?(@archive_dir) do
      @archive_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn filename ->
        path = Path.join(@archive_dir, filename)
        case File.read(path) do
          {:ok, content} ->
            data = Jason.decode!(content)
            %{id: data["id"], title: data["title"], timestamp: data["timestamp"]}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.timestamp, :desc)
    else
      []
    end
  end

  @doc "Loads a specific archive by session ID."
  def load_archive(session_id) do
    path = Path.join(@archive_dir, "#{session_id}.json")
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> {:ok, data}
            error -> error
          end
        error -> error
      end
    else
      {:error, :not_found}
    end
  end
end
