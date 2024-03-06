defmodule Web.Groups.Index do
  use Web, :live_view
  alias Domain.Actors

  def mount(_params, _session, socket) do
    sortable_fields = [
      {:groups, :name},
      {:groups, :inserted_at}
    ]

    {:ok, assign(socket, page_title: "Groups", sortable_fields: sortable_fields)}
  end

  def handle_params(params, uri, socket) do
    {socket, list_opts} =
      handle_rich_table_params(params, uri, socket, "groups", Actors.Group.Query,
        preload: [:provider, created_by_identity: [:actor]]
      )

    with {:ok, groups, metadata} <- Actors.list_groups(socket.assigns.subject, list_opts),
         {:ok, group_actors} <- Actors.peek_group_actors(groups, 3, socket.assigns.subject) do
      socket =
        assign(socket,
          groups: groups,
          metadata: metadata,
          group_actors: group_actors
        )

      {:noreply, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}><%= @page_title %></.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Groups
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/groups/new"}>
          Add Group
        </.add_button>
      </:action>
      <:content>
        <div class="bg-white overflow-hidden">
          <.rich_table
            id="groups"
            rows={@groups}
            row_id={&"user-#{&1.id}"}
            sortable_fields={@sortable_fields}
            filters={@filters}
            filter={@filter}
            metadata={@metadata}
          >
            <:col
              :let={group}
              label="NAME"
              class="w-2/4"
              field={{:groups, :name}}
              order_by={@order_by}
            >
              <.link navigate={~p"/#{@account}/groups/#{group.id}"} class={[link_style()]}>
                <%= group.name %>
              </.link>

              <span :if={Actors.group_deleted?(group)} class="text-xs text-neutral-100">
                (deleted)
              </span>
            </:col>
            <:col :let={group} label="ACTORS">
              <.peek peek={Map.fetch!(@group_actors, group.id)}>
                <:empty>
                  None
                </:empty>

                <:separator>
                  <span class="pr-1">,</span>
                </:separator>

                <:item :let={actor}>
                  <.link navigate={~p"/#{@account}/actors/#{actor}"} class={[link_style()]}>
                    <%= actor.name %>
                  </.link>
                </:item>

                <:tail :let={count}>
                  <span class="pl-1">
                    and <%= count %> more.
                  </span>
                </:tail>
              </.peek>
            </:col>
            <:col :let={group} label="SOURCE" field={{:groups, :inserted_at}} order_by={@order_by}>
              <.created_by account={@account} schema={group} />
            </:col>
            <:empty>
              <div class="flex justify-center text-center text-neutral-500 p-4">
                <div class="w-auto pb-4">
                  No groups to display.
                  <.link class={[link_style()]} navigate={~p"/#{@account}/groups/new"}>
                    Add a group manually
                  </.link>
                  or
                  <.link
                    class={[link_style()]}
                    navigate={~p"/#{@account}/settings/identity_providers"}
                  >
                    go to settings
                  </.link>
                  to sync groups from an identity provider.
                </div>
              </div>
            </:empty>
          </.rich_table>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_rich_table_event(event, params, socket)
end
