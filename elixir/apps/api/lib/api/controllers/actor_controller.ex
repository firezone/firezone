defmodule API.ActorController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.{Actors, Safe}
  alias __MODULE__.DB
  import Ecto.Changeset

  action_fallback API.FallbackController

  tags ["Actors"]

  operation :index,
    summary: "List Actors",
    parameters: [
      limit: [in: :query, description: "Limit Users returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"ActorsResponse", "application/json", API.Schemas.Actor.ListResponse}
    ]

  # List Actors
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actors, metadata} <- DB.list_actors(conn.assigns.subject, list_opts) do
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
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response}
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
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response}
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
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response}
    ]

  # Update an Actor
  def update(conn, %{"id" => id, "actor" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, subject),
         changeset <- actor_changeset(actor, params),
         {:ok, actor} <- update_actor(changeset, subject) do
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
      ok: {"ActorResponse", "application/json", API.Schemas.Actor.Response}
    ]

  # Delete an Actor
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, subject),
         {:ok, actor} <- delete_actor(actor, subject) do
      render(conn, :show, actor: actor)
    end
  end

  defp delete_actor(actor, subject) do
    actor
    |> Safe.scoped(subject)
    |> Safe.delete()
  end

  defp actor_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name, :email, :type])
    |> validate_required([:name, :type])
  end

  defp update_actor(changeset, subject) do
    changeset
    |> Safe.scoped(subject)
    |> Safe.update()
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Actors, Safe}

    def list_actors(subject, opts \\ []) do
      from(a in Actors.Actor, as: :actors)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:actors, :asc, :inserted_at},
        {:actors, :asc, :id}
      ]
    end
  end
end
