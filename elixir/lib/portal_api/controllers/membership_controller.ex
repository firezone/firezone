defmodule PortalAPI.MembershipController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias __MODULE__.Database
  import Ecto.Changeset

  tags ["Memberships"]

  operation :index,
    summary: "List Memberships",
    parameters: [
      group_id: [
        in: :path,
        description: "ID",
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [
        in: :query,
        description: "Limit Memberships returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Membership Response", "application/json", PortalAPI.Schemas.Membership.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"group_id" => group_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> Keyword.put(:filter, group_id: group_id)

    with {:ok, actors, metadata} <- Database.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :update_put,
    summary: "Update Memberships",
    parameters: [
      group_id: [
        in: :path,
        description: "ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Membership Attributes", "application/json", PortalAPI.Schemas.Membership.PutRequest,
       required: true},
    responses: [
      ok:
        {"Membership Response", "application/json",
         PortalAPI.Schemas.Membership.MembershipResponse}
    ]

  @spec update_put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_put(
        conn,
        %{"group_id" => group_id, "memberships" => attrs}
      ) do
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(group_id, subject),
         :ok <- validate_group_editable(group),
         changeset <- update_group_memberships_changeset(group, attrs),
         {:ok, group} <- Database.update_group(changeset, subject) do
      render(conn, :memberships, memberships: group.memberships)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update_put(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  operation :update_patch,
    summary: "Update an Membership",
    parameters: [
      group_id: [
        in: :path,
        description: "ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Membership Attributes", "application/json", PortalAPI.Schemas.Membership.PatchRequest,
       required: true},
    responses: [
      ok:
        {"Membership Response", "application/json",
         PortalAPI.Schemas.Membership.MembershipResponse}
    ]

  @spec update_patch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_patch(
        conn,
        %{"group_id" => group_id, "memberships" => params}
      ) do
    add = Map.get(params, "add", [])
    remove = Map.get(params, "remove", [])
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(group_id, subject),
         :ok <- validate_group_editable(group),
         membership_attrs <- prepare_membership_attrs(group, add, remove),
         changeset <- update_group_memberships_changeset(group, membership_attrs),
         {:ok, group} <- Database.update_group(changeset, subject) do
      render(conn, :memberships, memberships: group.memberships)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update_patch(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp validate_group_editable(group) do
    if is_nil(group.directory_id) and group.type == :static do
      :ok
    else
      {:error, :forbidden, reason: "Group is not editable"}
    end
  end

  defp update_group_memberships_changeset(group, attrs) do
    # Ensure all membership attrs include the account_id from the group
    attrs_with_account =
      Enum.map(attrs, fn membership_attrs ->
        Map.put_new(membership_attrs, "account_id", group.account_id)
      end)

    group
    |> cast(%{memberships: attrs_with_account}, [])
    |> cast_assoc(:memberships, with: &membership_changeset/2)
  end

  defp membership_changeset(membership, attrs) do
    import Ecto.Changeset

    membership
    |> cast(attrs, [:actor_id, :group_id, :account_id, :last_synced_at])
    |> Portal.Membership.changeset()
  end

  defp prepare_membership_attrs(group, add, remove) do
    to_add = MapSet.new(add) |> MapSet.reject(&(String.trim(&1) == ""))
    to_remove = MapSet.new(remove) |> MapSet.reject(&(String.trim(&1) == ""))
    member_ids = Enum.map(group.memberships, & &1.actor_id) |> MapSet.new()

    membership_ids =
      MapSet.difference(member_ids, to_remove)
      |> MapSet.union(to_add)

    if MapSet.size(membership_ids) == 0,
      do: [],
      else: Enum.map(membership_ids, &%{"actor_id" => &1, "account_id" => group.account_id})
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def list_actors(subject, opts) do
      from(a in Portal.Actor, as: :actors)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_group(id, subject) do
      from(g in Portal.Group, where: g.id == ^id)
      |> preload(:memberships)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
    end

    def update_group(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def cursor_fields do
      [
        {:actors, :asc, :inserted_at},
        {:actors, :asc, :id}
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :group_id,
          title: "Group",
          type: {:string, :uuid},
          fun: &filter_by_group_id/2
        }
      ]
    end

    defp filter_by_group_id(queryable, group_id) do
      dynamic =
        dynamic(
          [actors: a],
          a.id in subquery(
            from(m in Portal.Membership,
              where: m.group_id == ^group_id,
              select: m.actor_id
            )
          )
        )

      {queryable, dynamic}
    end
  end
end
