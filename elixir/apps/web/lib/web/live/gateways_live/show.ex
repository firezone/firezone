defmodule Web.GatewaysLive.Show do
  use Web, :live_view

  alias Domain.Gateways
  alias Domain.Resources

  def mount(%{"id" => id} = _params, _session, socket) do
    {:ok, gateway} = Gateways.fetch_gateway_by_id(id, socket.assigns.subject, preload: :group)
    {:ok, resources} = Resources.list_resources_for_gateway(gateway, socket.assigns.subject)
    {:ok, assign(socket, gateway: gateway, resources: resources)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/gateways"}>Gateways</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}"}>
        <%= @gateway.name_suffix %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Gateway: <code><%= @gateway.name_suffix %></code>
      </:title>
    </.header>
    <!-- Gateway details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table>
        <.vertical_table_row>
          <:label>Instance Group Name</:label>
          <:value><%= @gateway.group.name_prefix %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Instance Name</:label>
          <:value><%= @gateway.name_suffix %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Connectivity</:label>
          <:value>TODO: Peer to Peer</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Status</:label>
          <:value>
            <.badge type="success">TODO: Online</.badge>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Location</:label>
          <:value>
            <code>
              <%= @gateway.last_seen_remote_ip %>
            </code>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Last seen
          </:label>
          <:value>
            <.relative_datetime relative={@gateway.last_seen_at} />
            <br />
            <%= @gateway.last_seen_at %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv4</:label>
          <:value>
            <code><%= @gateway.ipv4 %></code>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv6</:label>
          <:value>
            <code><%= @gateway.ipv6 %></code>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Transfer</:label>
          <:value>TODO: 4.43 GB up, 1.23 GB down</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Gateway Version</:label>
          <:value>
            <%= "Gateway Version: #{@gateway.last_seen_version}" %>
            <br />
            <%= "User Agent: #{@gateway.last_seen_user_agent}" %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Deployment Method</:label>
          <:value>TODO: Docker</:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    <!-- Linked Resources table -->
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Linked Resources
        </h1>
      </div>
    </div>
    <div class="relative overflow-x-auto">
      <.table id="resources" rows={@resources}>
        <:col :let={resource} label="NAME">
          <.link
            navigate={~p"/#{@account}/resources/#{resource.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= resource.name %>
          </.link>
        </:col>
        <:col :let={resource} label="ADDRESS">
          <%= resource.address %>
        </:col>
      </.table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Delete Gateway
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
