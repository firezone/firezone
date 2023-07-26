defmodule Web.Devices.Show do
  use Web, :live_view

  alias Domain.Devices

  def mount(%{"id" => id} = _params, _session, socket) do
    {:ok, device} = Devices.fetch_device_by_id(id, socket.assigns.subject, preload: :actor)

    {:ok, assign(socket, device: device)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/devices"}>Devices</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/devices/#{@device.id}"}>
        <%= @device.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.header>
      <:title>
        Device Details
      </:title>
    </.header>
    <!-- Device Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table>
        <.vertical_table_row>
          <:label>Identifier</:label>
          <:value><%= @device.id %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Owner</:label>
          <:value>
            <.link
              navigate={~p"/#{@account}/actors/#{@device.actor.id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @device.actor.name %>
            </.link>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>First Seen</:label>
          <:value>TODO</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Seen</:label>
          <:value>TODO</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv4</:label>
          <:value><code><%= @device.ipv4 %></code></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv6</:label>
          <:value><code><%= @device.ipv6 %></code></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Transfer</:label>
          <:value>TODO</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Client Version</:label>
          <:value>TODO</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>OS Version</:label>
          <:value>TODO</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Machine Type</:label>
          <:value>TODO</:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Archive
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
