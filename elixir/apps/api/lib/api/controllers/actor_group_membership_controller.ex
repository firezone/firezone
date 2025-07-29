defmodule API.ActorGroupMembershipController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Actors
  alias OpenApiSpex.Reference

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
         API.Schemas.ActorGroupMembership.ListResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # List members for a given Actor Group
  def index(conn, %{"actor_group_id" => actor_group_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> Keyword.put(:filter, group_id: actor_group_id)

    with {:ok, actors, metadata} <- Actors.list_actors(conn.assigns.subject, list_opts) do
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
         API.Schemas.ActorGroupMembership.MembershipResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  def update_put(
        conn,
        %{"actor_group_id" => actor_group_id, "memberships" => attrs}
      ) do
    subject = conn.assigns.subject
    preload = [:memberships]
    filter = [deleted?: false, editable?: true]

    with {:ok, group} <-
           Actors.fetch_group_by_id(actor_group_id, subject, preload: preload, filter: filter),
         {:ok, group} <- Actors.update_group(group, %{memberships: attrs}, subject) do
      render(conn, :memberships, memberships: group.memberships)
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
         API.Schemas.ActorGroupMembership.MembershipResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Update Actor Group Memberships
  def update_patch(
        conn,
        %{"actor_group_id" => actor_group_id, "memberships" => params}
      ) do
    add = Map.get(params, "add", [])
    remove = Map.get(params, "remove", [])
    subject = conn.assigns.subject
    preload = [:memberships]
    filter = [deleted?: false, editable?: true]

    with {:ok, group} <-
           Actors.fetch_group_by_id(actor_group_id, subject, preload: preload, filter: filter),
         membership_attrs <- prepare_membership_attrs(group, add, remove),
         {:ok, group} <- Actors.update_group(group, %{memberships: membership_attrs}, subject) do
      render(conn, :memberships, memberships: group.memberships)
    end
  end

  def update_patch(_conn, _params) do
    {:error, :bad_request}
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
end
