defmodule API.ActorGroupController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Actors
  alias __MODULE__.DB
  import Ecto.Changeset

  action_fallback API.FallbackController

  tags ["Actor Groups"]

  operation :index,
    summary: "List Actor Groups",
    parameters: [
      limit: [in: :query, description: "Limit Actor Groups returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.ListResponse}
    ]

  # List Actor Groups
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actor_groups, metadata} <- DB.list_groups(conn.assigns.subject, list_opts) do
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
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response}
    ]

  # Show a specific Actor Group
  def show(conn, %{"id" => id}) do
    actor_group = DB.fetch_group(conn.assigns.subject, id)
    render(conn, :show, actor_group: actor_group)
  end

  operation :create,
    summary: "Create Actor Group",
    parameters: [],
    request_body:
      {"Actor Group Attributes", "application/json", API.Schemas.ActorGroup.Request,
       required: true},
    responses: [
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response}
    ]

  # Create a new Actor Group
  def create(conn, %{"actor_group" => params}) do
    params = Map.put(params, "type", "static")

    with changeset <- create_group_changeset(conn.assigns.subject.account, params),
         {:ok, actor_group} <- DB.insert_group(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/actor_groups/#{actor_group}")
      |> render(:show, actor_group: actor_group)
    end
  end

  defp create_group_changeset(account, attrs) do
    %Actors.Group{account_id: account.id}
    |> cast(attrs, [:name, :type, :description])
    |> validate_required([:name, :type])
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
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response}
    ]

  # Update an Actor Group
  def update(conn, %{"id" => id, "actor_group" => params}) do
    subject = conn.assigns.subject
    actor_group = DB.fetch_group(subject, id)

    with {:changeset, changeset} <- update_group_changeset(actor_group, params),
         {:ok, actor_group} <- DB.update_group(changeset, subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end

  defp update_group_changeset(%Actors.Group{type: :managed}, _attrs) do
    {:error, :managed_group}
  end

  defp update_group_changeset(%Actors.Group{directory: "firezone"} = group, attrs) do
    changeset =
      group
      |> cast(attrs, [:name, :description])
      |> validate_required([:name])
    
    {:changeset, changeset}
  end

  defp update_group_changeset(%Actors.Group{}, _attrs) do
    {:error, :synced_group}
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
      ok: {"Actor Group Response", "application/json", API.Schemas.ActorGroup.Response}
    ]

  # Delete an Actor Group
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject
    actor_group = DB.fetch_group(subject, id)

    with {:ok, actor_group} <- DB.delete_group(actor_group, subject) do
      render(conn, :show, actor_group: actor_group)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Actors, Safe, Repo}

    def list_groups(subject, opts \\ []) do
      from(g in Actors.Group, as: :groups)
      |> where(
        [groups: g],
        not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
      )
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_group(subject, id) do
      from(g in Actors.Group,
        where: g.id == ^id,
        where: not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
      )
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def insert_group(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update_group(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_group(%Actors.Group{} = group, subject) do
      group
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def cursor_fields do
      [
        {:groups, :asc, :inserted_at},
        {:groups, :asc, :id}
      ]
    end
  end
end
