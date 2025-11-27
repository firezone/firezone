defmodule API.ActorGroupMembershipController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Actors
  alias __MODULE__.DB
  import Ecto.Changeset

  action_fallback API.FallbackController

  tags ["Actor Group Memberships"]

  operation :index,
    summary: "List Actor Group Memberships",
    parameters: [
      actor_group_id: [
        in: :path,
        description: "Actor Group ID",
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [
        in: :query,
        description: "Limit Actor Group Memberships returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok:
        {"Actor Group Membership Response", "application/json",
         API.Schemas.ActorGroupMembership.ListResponse}
    ]

  # List members for a given Actor Group
  def index(conn, %{"actor_group_id" => actor_group_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> Keyword.put(:filter, group_id: actor_group_id)

    with {:ok, actors, metadata} <- DB.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    end
  end

  operation :update_put,
    summary: "Update Actor Group Memberships",
    parameters: [
      actor_group_id: [
        in: :path,
        description: "Actor Group ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Actor Group Membership Attributes", "application/json",
       API.Schemas.ActorGroupMembership.PutRequest, required: true},
    responses: [
      ok:
        {"Actor Group Membership Response", "application/json",
         API.Schemas.ActorGroupMembership.MembershipResponse}
    ]

  def update_put(
        conn,
        %{"actor_group_id" => actor_group_id, "memberships" => attrs}
      ) do
    subject = conn.assigns.subject

    with {:ok, group} <- DB.fetch_group_by_id(actor_group_id, subject),
         true <- is_nil(group.directory_id) and group.type == :static,
         changeset <- update_group_memberships_changeset(group, attrs),
         {:ok, group} <- DB.update_group(changeset, subject) do
      render(conn, :memberships, memberships: group.memberships)
    else
      false -> {:error, :not_editable}
      error -> error
    end
  end

  def update_put(_conn, _params) do
    {:error, :bad_request}
  end

  operation :update_patch,
    summary: "Update an Actor Group Membership",
    parameters: [
      actor_group_id: [
        in: :path,
        description: "Actor Group ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Actor Group Membership Attributes", "application/json",
       API.Schemas.ActorGroupMembership.PatchRequest, required: true},
    responses: [
      ok:
        {"Actor Group Membership Response", "application/json",
         API.Schemas.ActorGroupMembership.MembershipResponse}
    ]

  # Update Actor Group Memberships
  def update_patch(
        conn,
        %{"actor_group_id" => actor_group_id, "memberships" => params}
      ) do
    add = Map.get(params, "add", [])
    remove = Map.get(params, "remove", [])
    subject = conn.assigns.subject

    with {:ok, group} <- DB.fetch_group_by_id(actor_group_id, subject),
         true <- is_nil(group.directory_id) and group.type == :static,
         membership_attrs <- prepare_membership_attrs(group, add, remove),
         changeset <- update_group_memberships_changeset(group, membership_attrs),
         {:ok, group} <- DB.update_group(changeset, subject) do
      render(conn, :memberships, memberships: group.memberships)
    else
      false -> {:error, :not_editable}
      error -> error
    end
  end

  def update_patch(_conn, _params) do
    {:error, :bad_request}
  end

  defp update_group_memberships_changeset(group, attrs) do
    group
    |> cast(%{memberships: attrs}, [])
    |> cast_assoc(:memberships)
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
      else: Enum.map(membership_ids, &%{actor_id: &1})
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Actors, Safe}

    def list_actors(subject, opts) do
      from(a in Actors.Actor, as: :actors)
      |> Safe.scoped(subject)
      |> Safe.list(Actors.Actor.Query, opts)
    end

    def fetch_group_by_id(id, subject) do
      from(g in Actors.Group, where: g.id == ^id)
      |> preload(:memberships)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        group -> {:ok, group}
      end
    end

    def update_group(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
