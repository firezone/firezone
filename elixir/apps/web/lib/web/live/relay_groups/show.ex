defmodule Web.RelayGroups.Show do
  use Web, :live_view
  alias Domain.Relays

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Relays.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               relays: [token: [created_by_identity: [:actor]]],
               created_by_identity: [:actor]
             ]
           ) do
      :ok = Relays.subscribe_for_relays_presence_in_group(group)
      {:ok, assign(socket, group: group)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "relay_groups:" <> _account_id}, socket) do
    socket =
      redirect(socket, to: ~p"/#{socket.assigns.account}/relay_groups/#{socket.assigns.group}")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    # TODO: make sure tokens are all deleted too!
    {:ok, _group} = Relays.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/relay_groups")}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Relay Instance Group: <code><%= @group.name %></code>
      </:title>
      <:actions :if={@group.account_id}>
        <.edit_button navigate={~p"/#{@account}/relay_groups/#{@group}/edit"}>
          Edit Instance Group
        </.edit_button>
      </:actions>
    </.header>

    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="group">
        <.vertical_table_row>
          <:label>Instance Group Name</:label>
          <:value><%= @group.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Created</:label>
          <:value>
            <.created_by schema={@group} />
          </:value>
        </.vertical_table_row>
      </.vertical_table>
      <!-- Relays table -->
      <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
        <div class="col-span-full mb-4 xl:mb-2">
          <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
            Relay Instances
          </h1>
        </div>
      </div>
      <div class="relative overflow-x-auto">
        <.table id="relays" rows={@group.relays}>
          <:col :let={relay} label="INSTANCE">
            <.link
              navigate={~p"/#{@account}/relays/#{relay.id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <code :if={relay.ipv4} class="block text-xs">
                <%= relay.ipv4 %>
              </code>
              <code :if={relay.ipv6} class="block text-xs">
                <%= relay.ipv6 %>
              </code>
            </.link>
          </:col>
          <:col :let={relay} label="TOKEN CREATED AT">
            <.created_by schema={relay.token} />
          </:col>
          <:col :let={relay} label="STATUS">
            <.connection_status schema={relay} />
          </:col>
        </.table>
      </div>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions :if={@group.account_id}>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this relay group and disconnect all it's relays?"
        >
          Delete Relay Instance Group
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
