defmodule Web.Relays.Show do
  use Web, :live_view
  alias Domain.{Relays, Config}

  def mount(%{"id" => id}, _session, socket) do
    with true <- Config.self_hosted_relays_enabled?(),
         {:ok, relay} <-
           Relays.fetch_relay_by_id(id, socket.assigns.subject, preload: :group) do
      :ok = Relays.subscribe_for_relays_presence_in_group(relay.group)
      {:ok, assign(socket, relay: relay)}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@relay.group}"}>
        <%= @relay.group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relays/#{@relay}"}>
        <%= @relay.name || @relay.ipv4 || @relay.ipv6 %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Relay: <span :if={@relay.name}><%= @relay.name %></span>
        <.intersperse_blocks :if={is_nil(@relay.name)}>
          <:separator>,&nbsp;</:separator>

          <:item :for={ip <- [@relay.ipv4, @relay.ipv6]} :if={not is_nil(ip)}>
            <code><%= @relay.ipv4 %></code>
          </:item>
        </.intersperse_blocks>
        <span :if={not is_nil(@relay.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:content>
        <div class="bg-white overflow-hidden">
          <.vertical_table id="relay">
            <.vertical_table_row>
              <:label>Instance Group Name</:label>
              <:value><%= @relay.group.name %></:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Name</:label>
              <:value><%= @relay.name %></:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                IPv4
                <p class="text-xs">Set by <code>PUBLIC_IP4_ADDR</code></p>
              </:label>
              <:value>
                <code><%= @relay.ipv4 %></code>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                IPv6
                <p class="text-xs">Set by <code>PUBLIC_IP6_ADDR</code></p>
              </:label>
              <:value>
                <code><%= @relay.ipv6 %></code>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Status</:label>
              <:value>
                <.connection_status schema={@relay} />
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
              <:label>Remote IP</:label>
              <:value>
                <.last_seen schema={@relay} />
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
          </.vertical_table>
        </div>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@relay.deleted_at)}>
      <:action :if={@relay.account_id}>
        <.delete_button phx-click="delete" data-confirm="Are you sure you want to delete this relay?">
          Delete Relay
        </.delete_button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "relay_groups:" <> _account_id, payload: payload},
        socket
      ) do
    relay = socket.assigns.relay

    socket =
      cond do
        Map.has_key?(payload.joins, relay.id) ->
          assign(socket, relay: %{relay | online?: true})

        Map.has_key?(payload.leaves, relay.id) ->
          assign(socket, relay: %{relay | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _relay} = Relays.delete_relay(socket.assigns.relay, socket.assigns.subject)

    socket =
      push_navigate(socket,
        to: ~p"/#{socket.assigns.account}/relay_groups/#{socket.assigns.relay.group}"
      )

    {:noreply, socket}
  end
end
