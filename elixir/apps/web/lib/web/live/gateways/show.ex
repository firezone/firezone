defmodule Web.Gateways.Show do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(id, socket.assigns.subject, preload: :group) do
      :ok = Gateways.subscribe_to_gateways_presence_in_group(gateway.group)

      socket =
        assign(
          socket,
          gateway: gateway,
          page_title: "Gateway #{gateway.name}"
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway.group}"}>
        <%= @gateway.group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway.group}?#gateways"}>
        Gateways
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}"}>
        <%= @gateway.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Gateway: <code><%= @gateway.name %></code>
        <span :if={not is_nil(@gateway.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:content>
        <.vertical_table id="gateway">
          <.vertical_table_row>
            <:label>Site</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/sites/#{@gateway.group}"}
                class={["font-medium", link_style()]}
              >
                <%= @gateway.group.name %>
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @gateway.name %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Status</:label>
            <:value>
              <.connection_status schema={@gateway} />
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
            <:label>Last Seen Remote IP</:label>
            <:value>
              <.last_seen schema={@gateway} />
            </:value>
          </.vertical_table_row>
          <!--
        <.vertical_table_row>
          <:label>Transfer</:label>
          <:value>TODO: 4.43 GB up, 1.23 GB down</:value>
        </.vertical_table_row>
        -->
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
          <!--
        <.vertical_table_row>
          <:label>Deployment Method</:label>
          <:value>TODO: Docker</:value>
        </.vertical_table_row>
        -->
        </.vertical_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@gateway.deleted_at)}>
      <:action>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure you want to delete this gateway?"
        >
          Delete Gateway
        </.delete_button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id, payload: payload},
        socket
      ) do
    gateway = socket.assigns.gateway

    socket =
      cond do
        Map.has_key?(payload.joins, gateway.id) ->
          assign(socket, gateway: %{gateway | online?: true})

        Map.has_key?(payload.leaves, gateway.id) ->
          assign(socket, gateway: %{gateway | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _gateway} = Gateways.delete_gateway(socket.assigns.gateway, socket.assigns.subject)

    socket =
      push_navigate(socket,
        to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.gateway.group}"
      )

    {:noreply, socket}
  end
end
