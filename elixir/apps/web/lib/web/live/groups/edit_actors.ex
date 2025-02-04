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
          sortable_fields: [
            {:actors, :name}
          ],
          hide_filters: [:type, :provider_id, :status],
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
      {:ok,
       assign(socket,
         actors: actors,
         actors_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}"}>
        {@group.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}/edit_actors"}>
        Edit Actors
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Edit Actors in Group: <code>{@group.name}</code>
      </:title>
      <:content>
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"actor-#{&1.id}"}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} label="actor">
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
          <:col :let={actor} label="identities">
            <span class="flex flex-wrap gap-y-2">
              <.identity_identifier
                :for={identity <- actor.identities}
                account={@account}
                identity={identity}
              />
            </span>
          </:col>
          <:col :let={actor} class="w-1/6">
            <span class="flex justify-end">
              <.button
                :if={member?(@current_member_ids, actor, @added, @removed)}
                style="info"
                size="xs"
                icon="hero-minus"
                phx-click={:remove_actor}
                phx-value-id={actor.id}
              >
                Remove
              </.button>
              <.button
                :if={not member?(@current_member_ids, actor, @added, @removed)}
                style="info"
                size="xs"
                icon="hero-plus"
                phx-click={:add_actor}
                phx-value-id={actor.id}
              >
                Add
              </.button>
            </span>
          </:col>
        </.live_table>

        <div class="flex justify-end">
          <.button_with_confirmation
            id="save_changes"
            style={(@added == %{} and @removed == %{} && "disabled") || "primary"}
            confirm_style="primary"
            class="m-4"
            on_confirm="submit"
            disabled={@added == %{} and @removed == %{}}
          >
            <:dialog_title>Confirm changes to Group Actors</:dialog_title>
            <:dialog_content>
              <div class="mb-2">
                You're about to apply the following membership changes for the
                <strong>{@group.name}</strong>
                group:
              </div>

              <.confirm_message added={@added} removed={@removed} />
            </:dialog_content>
            <:dialog_confirm_button>
              Confirm
            </:dialog_confirm_button>
            <:dialog_cancel_button>
              Cancel
            </:dialog_cancel_button>
            Save
          </.button_with_confirmation>
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
    Enum.find_value(socket.assigns.actors, fn actor ->
      if actor.id == id, do: actor.name
    end)
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

  defp confirm_message(assigns) do
    ~H"""
    <ul>
      <li :for={{_id, name} <- @added} class="mb-2">
        <.icon name="hero-plus" class="h-3.5 w-3.5 mr-2 text-green-500" />
        {name}
      </li>

      <li :for={{_id, name} <- @removed} class="mb-2">
        <.icon name="hero-minus" class="h-3.5 w-3.5 mr-2 text-red-500" />
        {name}
      </li>
    </ul>
    """
  end
end
