defmodule API.ActorController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Actors
  alias OpenApiSpex.Reference

  action_fallback API.FallbackController

  tags ["Actors"]

  operation :index,
    summary: "List Actors",
    parameters: [
      limit: [in: :query, description: "Limit Users returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"ActorsResponse", "application/json", API.Schemas.Actor.ListResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # List Actors
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actors, metadata} <- Actors.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Actor",
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Show a specific Actor
  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Actors.fetch_actor_by_id(id, conn.assigns.subject) do
      render(conn, :show, actor: actor)
    end
  end

  operation :create,
    summary: "Create an Actor",
    request_body:
      {"Actor attributes", "application/json", API.Schemas.Actor.Request, required: true},
    responses: [
      created: {"ActorResponse", "application/json", API.Schemas.Actor.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Create a new Actor
  def create(conn, %{"actor" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.create_actor(subject.account, params, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/actors/#{actor}")
      |> render(:show, actor: actor)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  operation :update,
    summary: "Update an Actor",
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Actor attributes", "application/json", API.Schemas.Actor.Request, required: true},
    responses: [
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

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

  operation :delete,
    summary: "Delete an Actor",
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Delete an Actor
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, subject),
         {:ok, actor} <- Actors.delete_actor(actor, subject) do
      render(conn, :show, actor: actor)
    end
  end
end
