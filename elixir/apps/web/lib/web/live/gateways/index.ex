defmodule Web.GatewaysLive.Index do
  use Web, :live_view

  alias Domain.Gateways
  alias Domain.Resources

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject
    {:ok, gateways} = Gateways.list_gateways(subject, preload: :group)

    {_, resources} =
      Enum.map_reduce(gateways, %{}, fn g, acc ->
        {:ok, count} = Resources.count_resources_for_gateway(g, subject)
        {count, Map.put(acc, g.id, count)}
      end)

    grouped_gateways = Enum.group_by(gateways, fn g -> g.group end)

    socket =
      assign(socket,
        grouped_gateways: grouped_gateways,
        resources: resources
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/gateways"}>Gateways</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        All gateways
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/gateways/new"}>
          Add Instance Group
        </.add_button>
      </:actions>
    </.header>
    <!-- Gateways Table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.resource_filter />
      <.table_with_groups id="grouped-gateways" rows={@grouped_gateways} row_id={&"gateway-#{&1.id}"}>
        <:col label="INSTANCE GROUP"></:col>
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
            <%= gateway.ipv4 %>
          </code>
          <code class="block text-xs">
            <%= gateway.ipv6 %>
          </code>
        </:col>
        <:col :let={gateway} label="RESOURCES">
          <.badge>
            <%= @resources[gateway.id] || "0" %>
          </.badge>
        </:col>
        <:col :let={_gateway} label="STATUS">
          <.badge type="success">
            TODO: Online
          </.badge>
        </:col>
        <:action :let={gateway}>
          <.link
            navigate={~p"/#{@account}/gateways/#{gateway.id}"}
            class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Show
          </.link>
        </:action>
        <:action :let={_gateway}>
          <a
            href="#"
            class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Delete
          </a>
        </:action>
      </.table_with_groups>
      <.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/gateways"} />
    </div>
    """
  end

  defp resource_filter(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
      <div class="w-full md:w-1/2">
        <form class="flex items-center">
          <label for="simple-search" class="sr-only">Search</label>
          <div class="relative w-full">
            <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
            </div>
            <input
              type="text"
              id="simple-search"
              class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-500 focus:border-primary-500 block w-full pl-10 p-2 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
              placeholder="Search"
              required=""
            />
          </div>
        </form>
      </div>
      <.button_group>
        <:first>
          All
        </:first>
        <:middle>
          Online
        </:middle>
        <:last>
          Deleted
        </:last>
      </.button_group>
    </div>
    """
  end
end
