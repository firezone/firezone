defmodule Web.RelayGroups.Index do
  use Web, :live_view
  alias Domain.Relays

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    with true <- Domain.Config.self_hosted_relays_enabled?(),
         {:ok, groups} <- Relays.list_groups(subject, preload: [:relays]) do
      :ok = Relays.subscribe_for_relays_presence_in_account(socket.assigns.account)
      {:ok, assign(socket, groups: groups)}
    else
      _other -> raise Web.LiveErrors.NotFoundError
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
          <!--<.resource_filter />-->
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
                <%= group.name %>
              </.link>
              <span :if={is_nil(group.account_id)}>
                <%= group.name %>
              </span>
            </:group>

            <:col :let={relay} label="INSTANCE">
              <.link
                :if={relay.account_id}
                navigate={~p"/#{@account}/relays/#{relay.id}"}
                class={[link_style()]}
              >
                <code :if={relay.name} class="block text-xs">
                  <%= relay.name %>
                </code>
                <code :if={relay.ipv4} class="block text-xs">
                  <%= relay.ipv4 %>
                </code>
                <code :if={relay.ipv6} class="block text-xs">
                  <%= relay.ipv6 %>
                </code>
              </.link>
              <div :if={is_nil(relay.account_id)}>
                <code :if={relay.ipv4} class="block text-xs">
                  <%= relay.ipv4 %>
                </code>
                <code :if={relay.ipv6} class="block text-xs">
                  <%= relay.ipv6 %>
                </code>
              </div>
            </:col>

            <:col :let={relay} label="TYPE">
              <%= if relay.account_id, do: "self-hosted", else: "firezone-owned" %>
            </:col>

            <:col :let={relay} label="STATUS">
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
          <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/relay_groups"} />-->
        </div>
      </:content>
    </.section>
    """
  end

  def resource_filter(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
      <div class="w-full md:w-1/2">
        <form class="flex items-center">
          <label for="simple-search" class="sr-only">Search</label>
          <div class="relative w-full">
            <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-neutral-500" />
            </div>
            <input
              type="text"
              id="simple-search"
              class={[
                "bg-neutral-50 border border-neutral-300 text-neutral-900 text-sm rounded",
                "block w-full pl-10 p-2"
              ]}
              placeholder="Search"
              required=""
            />
          </div>
        </form>
      </div>
      <.button_group>
        <:first>
          All
        </:first>
        <:middle>
          Online
        </:middle>
        <:last>
          Deleted
        </:last>
      </.button_group>
    </div>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "relays" <> _account_id_or_nothing}, socket) do
    subject = socket.assigns.subject
    {:ok, groups} = Relays.list_groups(subject, preload: [:relays])
    {:noreply, assign(socket, groups: groups)}
  end
end
