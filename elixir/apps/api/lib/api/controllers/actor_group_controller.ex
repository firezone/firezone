defmodule API.ActorGroupController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Actors
  alias OpenApiSpex.Reference

  action_fallback API.FallbackController

  tags ["Actor Groups"]

  operation :index,
    summary: "List Actor Groups",
    parameters: [
      limit: [in: :query, description: "Limit Actor Groups returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.ListResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # List Actor Groups
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actor_groups, metadata} <- Actors.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, actor_groups: actor_groups, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Actor Group",
    parameters: [
      id: [
        in: :path,
        description: "Actor Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Show a specific Actor Group
  def show(conn, %{"id" => id}) do
    with {:ok, actor_group} <- Actors.fetch_group_by_id(id, conn.assigns.subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end

  operation :create,
    summary: "Create Actor Group",
    parameters: [],
    request_body:
      {"Actor Group Attributes", "application/json", API.Schemas.ActorGroup.Request,
       required: true},
    responses: [
      created: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Create a new Actor Group
  def create(conn, %{"actor_group" => params}) do
    params = Map.put(params, "type", "static")

    with {:ok, actor_group} <- Actors.create_group(params, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/actor_groups/#{actor_group}")
      |> render(:show, actor_group: actor_group)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  operation :update,
    summary: "Update a Actor Group",
    parameters: [
      id: [
        in: :path,
        description: "Actor Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Actor Group Attributes", "application/json", API.Schemas.ActorGroup.Request,
       required: true},
    responses: [
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Update an Actor Group
  def update(conn, %{"id" => id, "actor_group" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor_group} <- Actors.fetch_group_by_id(id, subject),
         {:ok, actor_group} <- Actors.update_group(actor_group, params, subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  operation :delete,
    summary: "Delete a Actor Group",
    parameters: [
      id: [
        in: :path,
        description: "Actor Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Delete an Actor Group
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor_group} <- Actors.fetch_group_by_id(id, subject),
         {:ok, actor_group} <- Actors.delete_group(actor_group, subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end
end
