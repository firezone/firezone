defmodule Web.Devices.Show do
  use Web, :live_view

  alias Domain.Devices

  def mount(%{"id" => id} = _params, _session, socket) do
    with {:ok, device} <- Devices.fetch_device_by_id(id, socket.assigns.subject, preload: :actor) do
      {:ok, assign(socket, device: device)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _device} = Devices.delete_device(socket.assigns.device, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/devices")}
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
      <:actions>
        <.edit_button navigate={~p"/#{@account}/devices/#{@device}/edit"}>
          Edit Device
        </.edit_button>
      </:actions>
    </.header>
    <!-- Device Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table>
        <.vertical_table_row>
          <:label>Identifier</:label>
          <:value><%= @device.id %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Name</:label>
          <:value><%= @device.name %></:value>
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
          <:label>Created</:label>
          <:value>
            <.relative_datetime datetime={@device.inserted_at} />
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Seen</:label>
          <:value>
            <.relative_datetime datetime={@device.last_seen_at} />
          </:value>
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
          <:value><%= @device.last_seen_version %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>User Agent</:label>
          <:value><%= @device.last_seen_user_agent %></:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button
          phx-click="delete"
          data-confirm={
            "Are you sure want to delete this device? " <>
            "User still will be able to create a new one by reconnecting to the Firezone."
          }
        >
          Delete
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
