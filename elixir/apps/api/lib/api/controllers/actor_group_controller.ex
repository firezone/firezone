defmodule API.ActorGroupController do
  alias Domain.Actors
  import API.ControllerHelpers
  use API, :controller

  action_fallback API.FallbackController

  # List Actor Groups
  def index(conn, params) do
    list_opts = params_to_list_opts(params)

    with {:ok, actor_groups, metadata} <- Actors.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, actor_groups: actor_groups, metadata: metadata)
    end
  end

  # Show a specific Actor Group
  def show(conn, %{"id" => id}) do
    with {:ok, actor_group} <- Actors.fetch_group_by_id(id, conn.assigns.subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end

  # Create a new Actor Group
  def create(conn, %{"actor_group" => params}) do
    params = Map.put(params, "type", "static")

    with {:ok, actor_group} <- Actors.create_group(params, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/actor_groups/#{actor_group}")
      |> render(:show, actor_group: actor_group)
    end
  end

  # Update an Actor Group
  def update(conn, %{"id" => id, "actor_group" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor_group} <- Actors.fetch_group_by_id(id, subject),
         {:ok, actor_group} <- Actors.update_group(actor_group, params, subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end

  # Delete an Actor Group
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor_group} <- Actors.fetch_group_by_id(id, subject),
         {:ok, actor_group} <- Actors.delete_group(actor_group, subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end
end
