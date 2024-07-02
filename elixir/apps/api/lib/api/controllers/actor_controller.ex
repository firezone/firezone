defmodule API.ActorController do
  use API, :controller
  alias API.Pagination
  alias Domain.Actors

  action_fallback API.FallbackController

  # List Actors
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actors, metadata} <- Actors.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    end
  end

  # Show a specific Actor
  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Actors.fetch_actor_by_id(id, conn.assigns.subject) do
      render(conn, :show, actor: actor)
    end
  end

  # Create a new Actor
  def create(conn, %{"actor" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.create_actor(subject.account, params, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/actors/#{actor}")
      |> render(:show, actor: actor)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  # Update an Actor
  def update(conn, %{"id" => id, "actor" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, subject),
         {:ok, actor} <- Actors.update_actor(actor, params, subject) do
      render(conn, :show, actor: actor)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  # Delete an Actor
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, subject),
         {:ok, actor} <- Actors.delete_actor(actor, subject) do
      render(conn, :show, actor: actor)
    end
  end
end
