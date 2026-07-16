defmodule PortalAPI.GroupController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Group
  alias __MODULE__.Database
  import Ecto.Changeset

  tags ["Groups"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Groups",
    parameters: [
      limit: [in: :query, description: "Limit Groups returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, groups, metadata} <- Database.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, groups: groups, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, group} <- Database.fetch_group(id, conn.assigns.subject) do
      render(conn, :show, group: group)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Create Group",
    parameters: [],
    request_body:
      {"Group Attributes", "application/json", PortalAPI.Schemas.Group.CreateRequest,
       required: true},
    responses:
      [created: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

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

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
      {"Group Attributes", "application/json", PortalAPI.Schemas.Group.UpdateRequest,
       required: true},
    responses:
      [ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

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

  # coveralls-ignore-start - unreachable: the update route always supplies an :id path param
  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-stop

  defp validate_group_updatable(%Group{idp_id: idp_id}) when not is_nil(idp_id),
    do: {:error, :forbidden, reason: "Cannot update a synced Group"}

  defp validate_group_updatable(_group), do: :ok

  defp do_update_group_changeset(%Group{type: :static, idp_id: nil} = group, attrs) do
    group
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Group Response", "application/json", PortalAPI.Schemas.Group.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

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
    alias Portal.{Group, Safe}

    def list_groups(subject, opts \\ []) do
      from(g in Group, as: :groups)
      |> where(
        [groups: g],
        not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
      )
      |> join(:left, [groups: g], gss in Portal.GroupSyncState,
        on: gss.group_id == g.id and gss.account_id == g.account_id,
        as: :sync_state
      )
      |> preload([sync_state: gss], sync_state: gss)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_group(id, subject) do
      result =
        from(g in Group,
          as: :groups,
          where: g.id == ^id,
          where: g.type != :managed
        )
        |> join(:left, [groups: g], gss in Portal.GroupSyncState,
          on: gss.group_id == g.id and gss.account_id == g.account_id,
          as: :sync_state
        )
        |> preload([sync_state: gss], sync_state: gss)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
    end

    def insert_group(changeset, subject) do
      # Manually-created groups never have a sync_state row; set it explicitly
      # so JSON rendering doesn't trip the loud-on-NotLoaded preload check.
      with {:ok, group} <- changeset |> Safe.scoped(subject) |> Safe.insert() do
        {:ok, %{group | sync_state: nil}}
      end
    end

    def update_group(changeset, subject) do
      # This controller only updates non-IdP groups (see validate_group_updatable),
      # so sync_state is always nil.
      with {:ok, group} <- changeset |> Safe.scoped(subject) |> Safe.update() do
        {:ok, %{group | sync_state: nil}}
      end
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
