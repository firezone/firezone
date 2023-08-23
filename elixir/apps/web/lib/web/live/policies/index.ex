defmodule Web.Policies.Index do
  use Web, :live_view
  alias Domain.Policies

  def mount(_params, _session, socket) do
    with {:ok, policies} <-
           Policies.list_policies(socket.assigns.subject, preload: [:actor_group, :resource]) do
      {:ok, assign(socket, policies: policies)}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        All Policies
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/policies/new"}>
          Add a new Policy
        </.add_button>
      </:actions>
    </.header>
    <!-- Policies table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.resource_filter />
      <.table id="policies" rows={@policies} row_id={&"policies-#{&1.id}"}>
        <:col :let={policy} label="NAME">
          <.link
            navigate={~p"/#{@account}/policies/#{policy}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= policy.name %>
          </.link>
        </:col>
        <:col :let={policy} label="GROUP">
          <.badge>
            <%= policy.actor_group.name %>
          </.badge>
        </:col>
        <:col :let={policy} label="RESOURCE">
          <.link
            navigate={~p"/#{@account}/resources/#{policy.resource_id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= policy.resource.name %>
          </.link>
        </:col>
        <:action :let={policy}>
          <.action_link navigate={~p"/#{@account}/policies/#{policy}/edit"}>
            Edit
          </.action_link>
        </:action>
        <:action :let={policy}>
          <div
            phx-click="delete"
            phx-value-id={policy.id}
            class="block py-2 px-4 cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Delete
          </div>
        </:action>
      </.table>
      <.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/gateway_groups"} />
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
    </div>
    """
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, policy} <- Policies.fetch_policy_by_id(id, socket.assigns.subject) do
      {:ok, _} = Policies.delete_policy(policy, socket.assigns.subject)
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/policies")}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end
end
