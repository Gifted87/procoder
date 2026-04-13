defmodule ProCoder.Core.OrchestrationLayer.SessionManagerImpl.PersistenceLayer do
  @moduledoc """
  Persistence layer for agent session management using Ecto.
  Handles saving, retrieving, and updating session state to ensure
  agent persistence and recovery.
  """

  alias ProCoder.Repo
  alias ProCoder.Persistence.Session

  @doc """
  Saves or updates an agent session.
  """
  def save_session(session_id, state) do
    # In this schema, session_id is likely the primary key (id) if it's a UUID
    case Repo.get(Session, session_id) do
      nil ->
        %Session{id: session_id}
        |> Session.changeset(%{context_snapshot: state})
        |> Repo.insert()

      session ->
        session
        |> Session.changeset(%{context_snapshot: state})
        |> Repo.update()
    end
  end

  @doc """
  Retrieves a session by ID.
  """
  def get_session(session_id) do
    Repo.get(Session, session_id)
  end

  @doc """
  Deletes a session.
  """
  def delete_session(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> Repo.delete(session)
    end
  end
end
