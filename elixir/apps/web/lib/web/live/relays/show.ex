defmodule Web.Relays.Show do
  use Web, :live_view
  alias Domain.Relays

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, relay} <-
           Relays.fetch_relay_by_id(id, socket.assigns.subject, preload: :group) do
      :ok = Relays.subscribe_for_relays_presence_in_group(relay.group)
      {:ok, assign(socket, relay: relay)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "relay_groups:" <> _account_id, payload: payload},
        socket
      ) do
    if Map.has_key?(payload.joins, socket.assigns.relay.id) or
         Map.has_key?(payload.leaves, socket.assigns.relay.id) do
      {:ok, relay} =
        Relays.fetch_relay_by_id(socket.assigns.relay.id, socket.assigns.subject, preload: :group)

      {:noreply, assign(socket, relay: relay)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _relay} = Relays.delete_relay(socket.assigns.relay, socket.assigns.subject)

    socket =
      redirect(socket,
        to: ~p"/#{socket.assigns.account}/relay_groups/#{socket.assigns.relay.group}"
      )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@relay.group}"}>
        <%= @relay.group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relays/#{@relay}"}>
        <%= @relay.ipv4 || @relay.ipv6 %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Relay:
        <.intersperse_blocks>
          <:separator>,&nbsp;</:separator>

          <:item :for={ip <- [@relay.ipv4, @relay.ipv6]} :if={not is_nil(ip)}>
            <code><%= @relay.ipv4 %></code>
          </:item>
        </.intersperse_blocks>
      </:title>
    </.header>
    <!-- Relay details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="relay">
        <.vertical_table_row>
          <:label>Instance Group Name</:label>
          <:value><%= @relay.group.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Status</:label>
          <:value>
            <.connection_status schema={@relay} />
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Location</:label>
          <:value>
            <code>
              <%= @relay.last_seen_remote_ip %>
            </code>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Last seen
          </:label>
          <:value>
            <.relative_datetime datetime={@relay.last_seen_at} />
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv4</:label>
          <:value>
            <code><%= @relay.ipv4 %></code>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv6</:label>
          <:value>
            <code><%= @relay.ipv6 %></code>
          </:value>
        </.vertical_table_row>

        <.vertical_table_row>
          <:label>Version</:label>
          <:value>
            <%= @relay.last_seen_version %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>User Agent</:label>
          <:value>
            <%= @relay.last_seen_user_agent %>
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
      <:actions :if={@relay.account_id}>
        <.delete_button phx-click="delete">
          Delete Relay
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
