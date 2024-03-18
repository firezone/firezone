defmodule Web.Groups.EditActors do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Actors.fetch_group_by_id(id, socket.assigns.subject,
             preload: [:memberships],
             filter: [
               deleted?: false,
               editable?: true
             ]
           ) do
      current_member_ids = Enum.map(group.memberships, & &1.actor_id)

      socket =
        socket
        |> assign(
          page_title: "Edit Actors in #{group.name}",
          group: group,
          current_member_ids: current_member_ids,
          added: %{},
          removed: %{}
        )
        |> assign_live_table("actors",
          query_module: Actors.Actor.Query,
          limit: 25,
          sortable_fields: [
            {:actors, :name}
          ],
          hide_filters: [:type, :provider_id],
          callback: &handle_actors_update!/2
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_actors_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, identities: :provider)

    with {:ok, actors, metadata} <- Actors.list_actors(socket.assigns.subject, list_opts) do
      assign(socket,
        actors: actors,
        actors_metadata: metadata
      )
    else
      {:error, :invalid_cursor} -> raise Web.LiveErrors.InvalidRequestError
      {:error, {:unknown_filter, _metadata}} -> raise Web.LiveErrors.InvalidRequestError
      {:error, {:invalid_type, _metadata}} -> raise Web.LiveErrors.InvalidRequestError
      {:error, {:invalid_value, _metadata}} -> raise Web.LiveErrors.InvalidRequestError
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
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
          <.live_table
            id="actors"
            rows={@actors}
            row_id={&"actor-#{&1.id}"}
            filters={@filters_by_table_id["actors"]}
            filter={@filter_form_by_table_id["actors"]}
            ordered_by={@order_by_table_id["actors"]}
            metadata={@actors_metadata}
          >
            <:col :let={actor} label="ACTOR">
              <.icon
                :if={removed?(actor, @removed)}
                name="hero-minus"
                class="h-3.5 w-3.5 mr-2 text-red-500"
              />
              <.icon
                :if={added?(actor, @added)}
                name="hero-plus"
                class="h-3.5 w-3.5 mr-2 text-green-500"
              />

              <.actor_name_and_role
                account={@account}
                actor={actor}
                class={
                  cond do
                    removed?(actor, @removed) -> "text-red-500"
                    added?(actor, @added) -> "text-green-500"
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
                :if={member?(@current_member_ids, actor, @added, @removed)}
                phx-click={:remove_actor}
                phx-value-id={actor.id}
              >
                <.icon name="hero-minus" class="h-3.5 w-3.5 mr-2" /> Remove
              </.button>
              <.button
                :if={not member?(@current_member_ids, actor, @added, @removed)}
                phx-click={:add_actor}
                phx-value-id={actor.id}
              >
                <.icon name="hero-plus" class="h-3.5 w-3.5 mr-2" /> Add
              </.button>
            </:col>
          </.live_table>

          <.button class="m-4" data-confirm={confirm_message(@added, @removed)} phx-click="submit">
            Save
          </.button>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("remove_actor", %{"id" => id}, socket) do
    if id in socket.assigns.current_member_ids do
      added = Map.delete(socket.assigns.added, id)
      removed = Map.put(socket.assigns.removed, id, actor_name(socket, id))
      {:noreply, assign(socket, added: added, removed: removed)}
    else
      added = Map.delete(socket.assigns.added, id)
      {:noreply, assign(socket, added: added)}
    end
  end

  def handle_event("add_actor", %{"id" => id}, socket) do
    if id in socket.assigns.current_member_ids do
      removed = Map.delete(socket.assigns.removed, id)
      {:noreply, assign(socket, removed: removed)}
    else
      added = Map.put(socket.assigns.added, id, actor_name(socket, id))
      removed = Map.delete(socket.assigns.removed, id)
      {:noreply, assign(socket, added: added, removed: removed)}
    end
  end

  def handle_event("submit", _params, socket) do
    filtered_memberships =
      Enum.flat_map(socket.assigns.group.memberships, fn membership ->
        if Map.has_key?(socket.assigns.removed, membership.actor_id) do
          []
        else
          [Map.from_struct(membership)]
        end
      end)

    new_memberships =
      Enum.map(socket.assigns.added, fn
        {id, _name} -> %{actor_id: id}
      end)

    attrs = %{memberships: filtered_memberships ++ new_memberships}

    with {:ok, group} <-
           Actors.update_group(socket.assigns.group, attrs, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups/#{group}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp actor_name(socket, id) do
    Enum.find_value(
      socket.assigns.actors,
      fn actor ->
        actor.id == id
      end,
      & &1.name
    )
  end

  defp member?(current_member_ids, actor, added, removed) do
    if actor.id in current_member_ids do
      not Map.has_key?(removed, actor.id)
    else
      Map.has_key?(added, actor.id)
    end
  end

  defp removed?(actor, removed) do
    Map.has_key?(removed, actor.id)
  end

  defp added?(actor, added) do
    Map.has_key?(added, actor.id)
  end

  # TODO: this should be replaced by a new state of a form which will render impact of a change
  defp confirm_message(added, removed) do
    added_names = Enum.map(added, fn {_id, name} -> name end)
    removed_names = Enum.map(removed, fn {_id, name} -> name end)

    add = if added_names != [], do: "add #{Enum.join(added_names, ", ")}"
    remove = if removed_names != [], do: "remove #{Enum.join(removed_names, ", ")}"
    change = [add, remove] |> Enum.reject(&is_nil/1) |> Enum.join(" and ")

    "Are you sure you want to #{change}?"
  end
end
