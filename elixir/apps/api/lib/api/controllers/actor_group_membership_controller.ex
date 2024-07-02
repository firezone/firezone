defmodule API.ActorGroupMembershipController do
  use API, :controller
  alias API.Pagination
  alias Domain.Actors

  action_fallback API.FallbackController

  # List members for a given Actor Group
  def index(conn, %{"actor_group_id" => actor_group_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> Keyword.put(:filter, group_id: actor_group_id)

    with {:ok, actors, metadata} <- Actors.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    end
  end

  # Update Actor Group Memberships
  def update(
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

  def update(_conn, _params) do
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
