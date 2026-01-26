defmodule PortalAPI.GroupController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias Portal.Group
  alias __MODULE__.Database
  import Ecto.Changeset

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

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, groups, metadata} <- Database.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, groups: groups, metadata: metadata)
    else
      error -> Error.handle(conn, error)
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

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, group} <- Database.fetch_group(id, conn.assigns.subject) do
      render(conn, :show, group: group)
    else
      error -> Error.handle(conn, error)
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

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"group" => params}) do
    with changeset <- create_group_changeset(conn.assigns.subject.account, params),
         {:ok, group} <- Database.insert_group(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/groups/#{group}")
      |> render(:show, group: group)
    else
      error -> Error.handle(conn, error)
    end
  end

  def create(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
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

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "group" => params}) do
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(id, subject),
         :ok <- validate_group_updatable(group),
         changeset = do_update_group_changeset(group, params),
         {:ok, group} <- Database.update_group(changeset, subject) do
      render(conn, :show, group: group)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(id, subject),
         :ok <- validate_group_updatable(group) do
      Error.handle(conn, {:error, :bad_request})
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp validate_group_updatable(%Group{type: :managed}),
    do: {:error, :forbidden, reason: "Cannot update a managed Group"}

  defp validate_group_updatable(%Group{idp_id: idp_id}) when not is_nil(idp_id),
    do: {:error, :forbidden, reason: "Cannot update a synced Group"}

  defp validate_group_updatable(_group), do: :ok

  defp do_update_group_changeset(%Group{type: :static, idp_id: nil} = group, attrs) do
    group
    |> cast(attrs, [:name])
    |> validate_required([:name])
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

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(id, subject),
         {:ok, group} <- Database.delete_group(group, subject) do
      render(conn, :show, group: group)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Group, Repo, Authorization}

    def list_groups(subject, opts \\ []) do
      Authorization.with_subject(subject, fn ->
        from(g in Group, as: :groups)
        |> where(
          [groups: g],
          not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
        )
        |> Repo.list(__MODULE__, opts)
      end)
    end

    def fetch_group(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(g in Group,
          where: g.id == ^id,
          where: g.type != :managed
        )
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          group -> {:ok, group}
        end
      end)
    end

    def insert_group(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Repo.insert(changeset)
      end)
    end

    def update_group(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Repo.update(changeset)
      end)
    end

    def delete_group(%Group{} = group, subject) do
      Authorization.with_subject(subject, fn ->
        Repo.delete(group)
      end)
    end

    def cursor_fields do
      [
        {:groups, :asc, :inserted_at},
        {:groups, :asc, :id}
      ]
    end
  end
end
