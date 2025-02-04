defmodule Web.Actors.EditGroups do
  use Web, :live_view
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [:memberships],
             filter: [
               deleted?: false
             ]
           ) do
      current_group_ids = Enum.map(actor.memberships, & &1.group_id)

      socket =
        socket
        |> assign(
          actor: actor,
          current_group_ids: current_group_ids,
          added: %{},
          removed: %{}
        )
        |> assign_live_table("groups",
          query_module: Actors.Group.Query,
          sortable_fields: [],
          hide_filters: [:provider_id],
          callback: &handle_groups_update!/2
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

  def handle_groups_update!(socket, list_opts) do
    with {:ok, groups, metadata} <-
           Actors.list_editable_groups(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         groups: groups,
         groups_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        {@actor.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}/edit_groups"}>
        Group Memberships
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Group Memberships: {@actor.name}
      </:title>
      <:help>
        Add or remove Groups for a given Actor.
      </:help>
      <:content>
        <.flash kind={:error} flash={@flash} />
        <.live_table
          id="groups"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
        >
          <:col :let={group} label="group">
            <.icon
              :if={removed?(group, @removed)}
              name="hero-minus"
              class="h-3.5 w-3.5 mr-2 text-red-500"
            />
            <.icon
              :if={added?(group, @added)}
              name="hero-plus"
              class="h-3.5 w-3.5 mr-2 text-green-500"
            />

            <.link
              navigate={~p"/#{@account}/groups/#{group}"}
              class={
                cond do
                  removed?(group, @removed) -> ["text-red-500"]
                  added?(group, @added) -> ["text-green-500"]
                  true -> []
                end ++ ["text-accent-500", "hover:underline"]
              }
            >
              {group.name}
            </.link>
          </:col>
          <:col :let={group}>
            <div class="flex justify-end">
              <.button
                :if={member?(@current_group_ids, group, @added, @removed)}
                size="xs"
                style="info"
                icon="hero-minus"
                phx-click={:remove_group}
                phx-value-id={group.id}
                phx-value-name={group.name}
              >
                Remove
              </.button>
              <.button
                :if={not member?(@current_group_ids, group, @added, @removed)}
                size="xs"
                style="info"
                icon="hero-plus"
                phx-click={:add_group}
                phx-value-id={group.id}
                phx-value-name={group.name}
              >
                Add
              </.button>
            </div>
          </:col>
        </.live_table>
        <div class="flex justify-between items-center">
          <div>
            <p
              :if={@actor.type == :account_user || @actor.type == :account_admin_user}
              class="px-4 text-sm text-gray-500"
            >
              Note: Users always belong to the default <strong>Everyone</strong> group.
            </p>
          </div>

          <.button_with_confirmation
            id="save_changes"
            style="primary"
            confirm_style="primary"
            class="m-4"
            on_confirm="submit"
          >
            <:dialog_title>Confirm changes to Actor Groups</:dialog_title>
            <:dialog_content>
              {confirm_message(@added, @removed)}
            </:dialog_content>
            <:dialog_confirm_button>
              Save
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

  def handle_event("add_group", %{"id" => id, "name" => name}, socket) do
    if id in socket.assigns.current_group_ids do
      removed = Map.delete(socket.assigns.removed, id)
      {:noreply, assign(socket, removed: removed)}
    else
      added = Map.put(socket.assigns.added, id, name)
      removed = Map.delete(socket.assigns.removed, id)
      {:noreply, assign(socket, added: added, removed: removed)}
    end
  end

  def handle_event("remove_group", %{"id" => id, "name" => name}, socket) do
    if id in socket.assigns.current_group_ids do
      added = Map.delete(socket.assigns.added, id)
      removed = Map.put(socket.assigns.removed, id, name)
      {:noreply, assign(socket, added: added, removed: removed)}
    else
      added = Map.delete(socket.assigns.added, id)
      {:noreply, assign(socket, added: added)}
    end
  end

  def handle_event("submit", _params, socket) do
    filtered_memberships =
      socket.assigns.actor.memberships
      |> remove_non_editable_memberships(socket.assigns.groups)
      |> Enum.flat_map(fn membership ->
        if Map.has_key?(socket.assigns.removed, membership.group_id) do
          []
        else
          [Map.from_struct(membership)]
        end
      end)

    new_memberships =
      Enum.map(socket.assigns.added, fn
        {id, _name} -> %{group_id: id}
      end)

    attrs =
      %{memberships: filtered_memberships ++ new_memberships}
      |> map_actor_memberships_attr()

    with {:ok, actor} <- Actors.update_actor(socket.assigns.actor, attrs, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/actors/#{actor}")
      {:noreply, socket}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}

      {:error, {:unauthorized, _context}} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  defp member?(current_group_ids, group, added, removed) do
    if group.id in current_group_ids do
      not Map.has_key?(removed, group.id)
    else
      Map.has_key?(added, group.id)
    end
  end

  defp removed?(group, removed) do
    Map.has_key?(removed, group.id)
  end

  defp added?(group, added) do
    Map.has_key?(added, group.id)
  end

  # TODO: this should be replaced by a new state of a form which will render impact of a change
  defp confirm_message(added, removed) do
    added_names = Enum.map(added, fn {_id, name} -> name end)
    removed_names = Enum.map(removed, fn {_id, name} -> name end)

    add = if added_names != [], do: "add #{Enum.join(added_names, ", ")}"
    remove = if removed_names != [], do: "remove #{Enum.join(removed_names, ", ")}"
    change = [add, remove] |> Enum.reject(&is_nil/1) |> Enum.join(" and ")

    if change == "" do
      # Don't show confirmation message if no changes were made
      nil
    else
      "Are you sure you want to #{change}?"
    end
  end

  defp remove_non_editable_memberships(memberships, editable_groups) do
    editable_group_ids =
      editable_groups
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Enum.filter(memberships, fn membership ->
      MapSet.member?(editable_group_ids, membership.group_id)
    end)
  end

  defp map_actor_memberships_attr(attrs) do
    Map.update(attrs, :memberships, [], fn memberships ->
      Enum.map(memberships, fn membership ->
        %{group_id: membership.group_id}
      end)
    end)
  end
end
