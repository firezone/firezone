defmodule Web.GatewayGroups.Show do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               gateways: [token: [created_by_identity: [:actor]]],
               connections: [:resource],
               created_by_identity: [:actor]
             ]
           ) do
      :ok = Gateways.subscribe_for_gateways_presence_in_group(group)
      {:ok, assign(socket, group: group)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/gateway_groups"}>Gateway Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateway_groups/#{@group}"}>
        <%= @group.name_prefix %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Gateway Instance Group: <code><%= @group.name_prefix %></code>
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/gateway_groups/#{@group}/edit"}>
          Edit Instance Group
        </.edit_button>
      </:action>

      <:content>
        <.vertical_table id="group">
          <.vertical_table_row>
            <:label>Instance Group Name</:label>
            <:value><%= @group.name_prefix %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Tags</:label>
            <:value>
              <div class="flex flex-wrap">
                <.badge :for={tag <- @group.tags} class="mb-2">
                  <%= tag %>
                </.badge>
              </div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <.created_by account={@account} schema={@group} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Gateway Instances</:title>
      <:content>
        <div class="relative overflow-x-auto">
          <.table id="gateways" rows={@group.gateways}>
            <:col :let={gateway} label="INSTANCE">
              <.link
                navigate={~p"/#{@account}/gateways/#{gateway.id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= gateway.name_suffix %>
              </.link>
            </:col>
            <:col :let={gateway} label="REMOTE IP">
              <code class="block text-xs">
                <%= gateway.last_seen_remote_ip %>
              </code>
            </:col>
            <:col :let={gateway} label="TOKEN CREATED AT">
              <.created_by account={@account} schema={gateway.token} />
            </:col>
            <:col :let={gateway} label="STATUS">
              <.connection_status schema={gateway} />
            </:col>
          </.table>
        </div>
      </:content>
    </.section>

    <.section>
      <:title>
        Linked Resources
      </:title>
      <:content>
        <div class="relative overflow-x-auto">
          <.table id="resources" rows={@group.connections} row_item={& &1.resource}>
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
      </:content>
    </.section>

    <.section>
      <:title>Danger Zone</:title>
      <:action>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this gateway group and disconnect all it's gateways?"
        >
          Delete Instance Group
        </.delete_button>
      </:action>
      <:content></:content>
    </.section>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id}, socket) do
    socket =
      redirect(socket, to: ~p"/#{socket.assigns.account}/gateway_groups/#{socket.assigns.group}")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    # TODO: make sure tokens are all deleted too!
    {:ok, _group} = Gateways.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/gateway_groups")}
  end
end
