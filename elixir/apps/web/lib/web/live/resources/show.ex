defmodule Web.Resources.Show do
  use Web, :live_view

  alias Domain.Resources

  def mount(%{"id" => id}, _session, socket) do
    {:ok, resource} =
      Resources.fetch_resource_by_id(id, socket.assigns.subject,
        preload: [:gateway_groups, created_by_identity: [:actor]]
      )

    {:ok, assign(socket, resource: resource)}
  end

  defp pretty_print_filter(filter) do
    case filter.protocol do
      :all ->
        "All Traffic Allowed"

      :icmp ->
        "ICPM: Allowed"

      :tcp ->
        "TCP: #{Enum.join(filter.ports, ", ")}"

      :udp ->
        "UDP: #{Enum.join(filter.ports, ", ")}"
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
        Jira
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Resource: <code><%= @resource.name %></code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/resources/#{@resource.id}/edit"}>
          Edit Resource
        </.edit_button>
      </:actions>
    </.header>
    <!-- Resource details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table>
        <.vertical_table_row>
          <:label>
            Name
          </:label>
          <:value>
            <%= @resource.name %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Address
          </:label>
          <:value>
            <%= @resource.address %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Traffic Filtering Rules
          </:label>
          <:value>
            <div :if={@resource.filters == []} %>
              No traffic filtering rules
            </div>
            <div :for={filter <- @resource.filters} :if={@resource.filters != []} %>
              <code>
                <%= pretty_print_filter(filter) %>
              </code>
            </div>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Created
          </:label>
          <:value>
            <.created_by account={@account} schema={@resource} />
          </:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    <!-- Linked Gateways table -->
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Linked Gateway Instance Groups
        </h1>
      </div>
    </div>
    <div class="relative overflow-x-auto">
      <.table id="gateway_instance_groups" rows={@resource.gateway_groups}>
        <:col :let={gateway_group} label="NAME">
          <.link
            navigate={~p"/#{@account}/gateway_groups"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= gateway_group.name_prefix %>
          </.link>
        </:col>
      </.table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Delete Resource
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
