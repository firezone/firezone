defmodule Web.RelayGroups.Index do
  use Web, :live_view
  alias Domain.{Accounts, Relays}

  def mount(_params, _session, socket) do
    if Accounts.self_hosted_relays_enabled?(socket.assigns.account) do
      if connected?(socket) do
        :ok = Relays.subscribe_to_relays_presence_in_account(socket.assigns.account)
      end

      socket =
        socket
        |> assign(page_title: "Relays")
        |> assign_live_table("groups",
          query_module: Relays.Group.Query,
          sortable_fields: [],
          callback: &handle_groups_update!/2
        )

      {:ok, socket}
    else
      raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_groups_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, relays: [:online?])

    with {:ok, groups, metadata} <- Relays.list_groups(socket.assigns.subject, list_opts) do
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
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>Relays</:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/relay_groups/new"}>
          Add Instance Group
        </.add_button>
      </:action>
      <:content>
        <div class="bg-white overflow-hidden">
          <.table_with_groups
            id="groups"
            groups={@groups}
            group_items={& &1.relays}
            group_id={&"group-#{&1.id}"}
            row_id={&"relay-#{&1.id}"}
          >
            <:group :let={group}>
              <.link
                :if={not is_nil(group.account_id)}
                navigate={~p"/#{@account}/relay_groups/#{group.id}"}
                class={["font-medium", link_style()]}
              >
                {group.name}
              </.link>
              <span :if={is_nil(group.account_id)}>
                {group.name}
              </span>
            </:group>

            <:col :let={relay} label="instance">
              <.link
                :if={relay.account_id}
                navigate={~p"/#{@account}/relays/#{relay.id}"}
                class={[link_style()]}
              >
                <code :if={relay.name} class="block text-xs">
                  {relay.name}
                </code>
                <code :if={relay.ipv4} class="block text-xs">
                  {relay.ipv4}
                </code>
                <code :if={relay.ipv6} class="block text-xs">
                  {relay.ipv6}
                </code>
              </.link>
              <div :if={is_nil(relay.account_id)}>
                <code :if={relay.ipv4} class="block text-xs">
                  {relay.ipv4}
                </code>
                <code :if={relay.ipv6} class="block text-xs">
                  {relay.ipv6}
                </code>
              </div>
            </:col>

            <:col :let={relay} label="type">
              {if relay.account_id, do: "self-hosted", else: "firezone-owned"}
            </:col>

            <:col :let={relay} label="status">
              <.connection_status schema={relay} />
            </:col>
            <:empty>
              <div class="flex justify-center text-center text-neutral-500 p-4">
                <div class="w-auto">
                  <div class="pb-4">
                    No relay instance groups to display
                  </div>
                  <.add_button navigate={~p"/#{@account}/relay_groups/new"}>
                    Add Instance Group
                  </.add_button>
                </div>
              </div>
            </:empty>
          </.table_with_groups>

          <.paginator id="relays" metadata={@groups_metadata} rows_count={length(@groups)} />
        </div>
      </:content>
    </.section>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "presences:" <> _rest}, socket) do
    {:noreply, reload_live_table!(socket, "groups")}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)
end
