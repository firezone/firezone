defmodule Web.Users.Index do
  use Web, :live_view

  alias Domain.Actors

  def mount(_params, _session, socket) do
    {_, actors} = Actors.list_actors(socket.assigns.subject, preload: [identities: :provider])

    {:ok, assign(socket, actors: actors)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Users</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        All users
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/actors/new"}>
          Add a new user
        </.add_button>
      </:actions>
    </.header>
    <!-- Users Table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.resource_filter />
      <.table id="users" rows={@actors} row_id={&"user-#{&1.id}"}>
        <:col :let={user} label="NAME" sortable="false">
          <.link
            navigate={~p"/#{@account}/actors/#{user.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= user.name %>
          </.link>
        </:col>
        <:col :let={user} label="IDENTIFIERS" sortable="false">
          <%= for identity <- user.identities do %>
            <%= "#{identity.provider.name}: #{identity.provider_identifier}" %>
            <br />
          <% end %>
        </:col>
        <:col :let={_user} label="GROUPS" sortable="false">
          <!-- TODO: Determine how user groups will work -->
          <%= "TODO Admin, Engineering, 3 more..." %>
        </:col>
        <:col :let={_user} label="LAST ACTIVE" sortable="false">
          <!-- TODO: Determine what last active means for a user -->
          <%= "TODO Today at 2:30pm" %>
        </:col>
        <:action>
          <.link
            navigate={~p"/#{@account}/actors/#{@subject.actor.id}"}
            class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Show
          </.link>
        </:action>
        <:action>
          <.link
            navigate={~p"/#{@account}/actors/#{@subject.actor.id}/edit"}
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
      <.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/actors"} />
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
    </div>
    """
  end
end
