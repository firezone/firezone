defmodule Web.Groups.EditActors do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Actors.fetch_group_by_id(id, socket.assigns.subject, preload: [:memberships]),
         nil <- group.deleted_at,
         false <- Actors.group_synced?(group),
         {:ok, actors} <-
           Actors.list_actors(socket.assigns.subject, preload: [identities: :provider]) do
      current_member_ids = Enum.map(group.memberships, & &1.actor_id)

      {:ok,
       assign(socket,
         group: group,
         current_member_ids: current_member_ids,
         actors: actors,
         added_ids: [],
         removed_ids: [],
         page_title: "Groups"
       )}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}/edit_actors"}>
        Edit Actors
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Edit Actors in Group: <code><%= @group.name %></code>
      </:title>
      <:content>
        <div class="relative overflow-x-auto">
          <.table id="actors" rows={@actors} row_id={&"actor-#{&1.id}"}>
            <:col :let={actor} label="ACTOR">
              <.icon
                :if={removed?(actor, @removed_ids)}
                name="hero-minus"
                class="h-3.5 w-3.5 mr-2 text-red-500"
              />
              <.icon
                :if={added?(actor, @added_ids)}
                name="hero-plus"
                class="h-3.5 w-3.5 mr-2 text-green-500"
              />

              <.actor_name_and_role
                account={@account}
                actor={actor}
                class={
                  cond do
                    removed?(actor, @removed_ids) -> "text-red-500"
                    added?(actor, @added_ids) -> "text-green-500"
                    true -> ""
                  end
                }
              />
            </:col>
            <:col :let={actor} label="IDENTITIES">
              <.identity_identifier
                :for={identity <- actor.identities}
                account={@account}
                identity={identity}
              />
            </:col>
            <:col :let={actor} class="w-1/6">
              <.button
                :if={member?(@current_member_ids, actor, @added_ids, @removed_ids)}
                phx-click={:remove_actor}
                phx-value-id={actor.id}
              >
                <.icon name="hero-minus" class="h-3.5 w-3.5 mr-2" /> Remove
              </.button>
              <.button
                :if={not member?(@current_member_ids, actor, @added_ids, @removed_ids)}
                phx-click={:add_actor}
                phx-value-id={actor.id}
              >
                <.icon name="hero-plus" class="h-3.5 w-3.5 mr-2" /> Add
              </.button>
            </:col>
          </.table>

          <.button
            class="m-4"
            data-confirm={confirm_message(@actors, @added_ids, @removed_ids)}
            phx-click="submit"
          >
            Save
          </.button>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("remove_actor", %{"id" => id}, socket) do
    if id in socket.assigns.current_member_ids do
      added_ids = socket.assigns.added_ids -- [id]
      removed_ids = [id] ++ socket.assigns.removed_ids
      {:noreply, assign(socket, added_ids: added_ids, removed_ids: removed_ids)}
    else
      added_ids = socket.assigns.added_ids -- [id]
      {:noreply, assign(socket, added_ids: added_ids)}
    end
  end

  def handle_event("add_actor", %{"id" => id}, socket) do
    if id in socket.assigns.current_member_ids do
      removed_ids = socket.assigns.removed_ids -- [id]
      {:noreply, assign(socket, removed_ids: removed_ids)}
    else
      added_ids = [id] ++ socket.assigns.added_ids
      removed_ids = socket.assigns.removed_ids -- [id]
      {:noreply, assign(socket, added_ids: added_ids, removed_ids: removed_ids)}
    end
  end

  def handle_event("submit", _params, socket) do
    memberships =
      Enum.flat_map(socket.assigns.group.memberships, fn membership ->
        if membership.actor_id in socket.assigns.removed_ids do
          []
        else
          [Map.from_struct(membership)]
        end
      end)

    add_memberships = Enum.map(socket.assigns.added_ids, fn id -> %{actor_id: id} end)

    attrs = %{memberships: memberships ++ add_memberships}

    with {:ok, group} <-
           Actors.update_group(socket.assigns.group, attrs, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups/#{group}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp member?(current_member_ids, actor, added_ids, removed_ids) do
    if actor.id in current_member_ids do
      actor.id not in removed_ids
    else
      actor.id in added_ids
    end
  end

  defp removed?(actor, removed_ids) do
    actor.id in removed_ids
  end

  defp added?(actor, added_ids) do
    actor.id in added_ids
  end

  # TODO: this should be replaced by a new state of a form which will render impact of a change
  defp confirm_message(actors, added_ids, removed_ids) do
    actors_by_id = Enum.into(actors, %{}, fn actor -> {actor.id, actor} end)
    added_names = Enum.map(added_ids, fn id -> Map.get(actors_by_id, id).name end)
    removed_names = Enum.map(removed_ids, fn id -> Map.get(actors_by_id, id).name end)

    add = if added_names != [], do: "add #{Enum.join(added_names, ", ")}"
    remove = if removed_names != [], do: "remove #{Enum.join(removed_names, ", ")}"
    change = [add, remove] |> Enum.reject(&is_nil/1) |> Enum.join(" and ")

    "Are you sure you want to #{change}?"
  end
end
