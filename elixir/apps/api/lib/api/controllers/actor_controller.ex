defmodule API.ActorController do
  alias Domain.Actors
  import API.ControllerHelpers
  use API, :controller

  action_fallback API.FallbackController

  # List Actors
  def index(conn, params) do
    list_opts = params_to_list_opts(params)

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

    with {:ok, account} <- Domain.Accounts.fetch_account_by_id(subject.account.id, subject),
         {:ok, actor} <- Actors.create_actor(account, params, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/actors/#{actor}")
      |> render(:show, actor: actor)
    end
  end

  # Update an Actor
  def update(conn, %{"id" => id, "actor" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, subject),
         {:ok, actor} <- Actors.update_actor(actor, params, subject) do
      render(conn, :show, actor: actor)
    end
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
