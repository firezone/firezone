defmodule Web.ResourcesLive.Index do
  use Web, :live_view

  alias Domain.Resources

  def mount(_params, _session, socket) do
    {_, resources} =
      Resources.list_resources(socket.assigns.subject, preload: :gateway_groups)

    {:ok, assign(socket, resources: resources)}
  end

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Resources", path: ~p"/#{@subject.account}/resources"}
        ]} />
      </:breadcrumbs>
      <:title>
        All Resources
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@subject.account}/resources/new"}>
          Add Resource
        </.add_button>
      </:actions>
    </.section_header>
    <!-- Resources Table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.resource_filter />
      <.table id="resources" rows={@resources} row_id={&"resource-#{&1.id}"}>
        <:col :let={resource} label="NAME">
          <.link
            navigate={~p"/#{@subject.account}/resources/#{resource.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= resource.name %>
          </.link>
        </:col>
        <:col :let={resource} label="ADDRESS">
          <code class="block text-xs">
            <%= resource.address %>
          </code>
        </:col>
        <:col :let={resource} label="GATEWAY INSTANCE GROUP">
          <.link
            :for={gateway_group <- resource.gateway_groups}
            navigate={~p"/#{@subject.account}/gateways"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <.badge type="info">
              <%= gateway_group.name_prefix %>
            </.badge>
          </.link>
        </:col>
        <:col :let={_resource} label="GROUPS">
          TODO
          <.link navigate={~p"/#{@subject.account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
            <.badge>Engineering</.badge>
          </.link>

          <.link navigate={~p"/#{@subject.account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
            <.badge>IT</.badge>
          </.link>
        </:col>
        <:action :let={resource}>
          <.link
            navigate={~p"/#{@subject.account}/resources/#{resource.id}"}
            class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Show
          </.link>
        </:action>
        <:action :let={resource}>
          <.link
            navigate={~p"/#{@subject.account}/resources/#{resource.id}/edit"}
            class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Edit
          </.link>
        </:action>
        <:action>
          <a
            href="#"
            class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Delete
          </a>
        </:action>
      </.table>
      <.paginator
        page={3}
        total_pages={100}
        collection_base_path={~p"/#{@subject.account}/resources"}
      />
    </div>
    """
  end

  def resource_filter(assigns) do
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
      <!-- TODO: These are likely not needed for Resources -->
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
