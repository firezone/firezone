defmodule PortalAPI.GroupController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias Portal.Group
  alias __MODULE__.DB
  import Ecto.Changeset

  action_fallback PortalAPI.FallbackController

  tags ["Groups"]

  operation :index,
    summary: "List Groups",
    parameters: [
      limit: [in: :query, description: "Limit Groups returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.ListResponse}
    ]

  # List Groups
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, groups, metadata} <- DB.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, groups: groups, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Group",
    parameters: [
      id: [
        in: :path,
        description: "Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}
    ]

  # Show a specific Group
  def show(conn, %{"id" => id}) do
    with {:ok, group} <- DB.fetch_group(id, conn.assigns.subject) do
      render(conn, :show, group: group)
    end
  end

  operation :create,
    summary: "Create Group",
    parameters: [],
    request_body:
      {"Group Attributes", "application/json", PortalAPI.Schemas.Group.Request, required: true},
    responses: [
      ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}
    ]

  # Create a new Group
  def create(conn, %{"group" => params}) do
    with changeset <- create_group_changeset(conn.assigns.subject.account, params),
         {:ok, group} <- DB.insert_group(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/groups/#{group}")
      |> render(:show, group: group)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  defp create_group_changeset(account, attrs) do
    %Group{account_id: account.id}
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  operation :update,
    summary: "Update a Group",
    parameters: [
      id: [
        in: :path,
        description: "Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Group Attributes", "application/json", PortalAPI.Schemas.Group.Request, required: true},
    responses: [
      ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}
    ]

  # Update an Group
  def update(conn, %{"id" => id, "group" => params}) do
    subject = conn.assigns.subject

    with {:ok, group} <- DB.fetch_group(id, subject),
         {:changeset, changeset} <- update_group_changeset(group, params),
         {:ok, group} <- DB.update_group(changeset, subject) do
      render(conn, :show, group: group)
    end
  end

  def update(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, group} <- DB.fetch_group(id, subject),
         {:changeset, _changeset} <- update_group_changeset(group, %{}) do
      {:error, :bad_request}
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  defp update_group_changeset(%Group{type: :managed}, _attrs) do
    {:error, :update_managed_group}
  end

  defp update_group_changeset(%Group{idp_id: idp_id}, _attrs) when not is_nil(idp_id) do
    {:error, :update_synced_group}
  end

  defp update_group_changeset(%Group{type: :static, idp_id: nil} = group, attrs) do
    changeset =
      group
      |> cast(attrs, [:name])
      |> validate_required([:name])

    {:changeset, changeset}
  end

  operation :delete,
    summary: "Delete a Group",
    parameters: [
      id: [
        in: :path,
        description: "Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}
    ]

  # Delete an Group
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, group} <- DB.fetch_group(id, subject),
         {:ok, group} <- DB.delete_group(group, subject) do
      render(conn, :show, group: group)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Group, Safe}

    def list_groups(subject, opts \\ []) do
      from(g in Group, as: :groups)
      |> where(
        [groups: g],
        not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
      )
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_group(id, subject) do
      result =
        from(g in Group,
          where: g.id == ^id,
          where: g.type != :managed
        )
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
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

    def delete_group(%Group{} = group, subject) do
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
