defmodule Web.Gateways.Show do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id} = _params, _session, socket) do
    with {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(id, socket.assigns.subject, preload: :group) do
      :ok = Gateways.subscribe_for_gateways_presence_in_group(gateway.group)
      {:ok, assign(socket, gateway: gateway)}
    else
      {:error, :not_found} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id, payload: payload},
        socket
      ) do
    if Map.has_key?(payload.joins, socket.assigns.gateway.id) or
         Map.has_key?(payload.leaves, socket.assigns.gateway.id) do
      {:ok, gateway} =
        Gateways.fetch_gateway_by_id(socket.assigns.gateway.id, socket.assigns.subject,
          preload: :group
        )

      {:noreply, assign(socket, gateway: gateway)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _gateway} = Gateways.delete_gateway(socket.assigns.gateway, socket.assigns.subject)

    socket =
      redirect(socket,
        to: ~p"/#{socket.assigns.account}/gateway_groups/#{socket.assigns.gateway.group}"
      )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/gateway_groups"}>Gateway Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateway_groups/#{@gateway.group}"}>
        <%= @gateway.group.name_prefix %>
      </.breadcrumb>
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
            <.connection_status schema={@gateway} />
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
            <.relative_datetime datetime={@gateway.last_seen_at} />
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
          <:label>Version</:label>
          <:value>
            <%= @gateway.last_seen_version %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>User Agent</:label>
          <:value>
            <%= @gateway.last_seen_user_agent %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Deployment Method</:label>
          <:value>TODO: Docker</:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button phx-click="delete">
          Delete Gateway
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
