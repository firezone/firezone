defmodule Web.Actors.Index do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    with {:ok, actors} <-
           Actors.list_actors(socket.assigns.subject,
             preload: [identities: :provider, groups: []]
           ) do
      {:ok, assign(socket, actors: actors)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp last_seen_at(identities) do
    identities
    |> Enum.reject(&is_nil(&1.last_seen_at))
    |> Enum.max_by(& &1.last_seen_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      identity -> identity.last_seen_at
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Actors
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/actors/new_user"}>
          Add a new User
        </.add_button>
        <.add_button navigate={~p"/#{@account}/actors/new_service_account"}>
          Add a new Service Account
        </.add_button>
      </:actions>
    </.header>
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <!--<.resource_filter />-->
      <.table id="actors" rows={@actors} row_id={&"user-#{&1.id}"}>
        <:col :let={actor} label="NAME" sortable="false">
          <.actor_name_and_role account={@account} actor={actor} />
        </:col>
        <:col :let={actor} label="IDENTIFIERS" sortable="false">
          <.identity_identifier :for={identity <- actor.identities} identity={identity} />
        </:col>
        <:col :let={actor} label="GROUPS" sortable="false">
          <span :for={group <- actor.groups}>
            <.link navigate={~p"/#{@account}/groups/#{group.id}"}>
              <.badge>
                <%= group.name %>
              </.badge>
            </.link>
          </span>
        </:col>
        <:col :let={actor} label="LAST SIGNED IN" sortable="false">
          <.relative_datetime datetime={last_seen_at(actor.identities)} />
        </:col>
      </.table>
      <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/actors"} />-->
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
      <.button_group>
        <:first>
          All
        </:first>
        <:middle>
          Users
        </:middle>
        <:last>
          Service Accounts
        </:last>
      </.button_group>
    </div>
    """
  end
end
