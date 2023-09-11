defmodule Web.Policies.Show do
  use Web, :live_view
  alias Domain.Policies

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource, [created_by_identity: :actor]]
           ) do
      {:ok, assign(socket, policy: policy)}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp pretty_print_date(date) do
    "#{date.month}/#{date.day}/#{date.year} #{date.hour}:#{date.minute}:#{date.second}"
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <%= @policy.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing Policy <code><%= @policy.name %></code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/policies/#{@policy}/edit"}>
          Edit Policy
        </.edit_button>
      </:actions>
    </.header>
    <!-- Show Policy -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table>
        <.vertical_table_row>
          <:label>
            Name
          </:label>
          <:value>
            <%= @policy.name %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Group
          </:label>
          <:value>
            <.link
              navigate={~p"/#{@account}/groups/#{@policy.actor_group_id}"}
              class="text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @policy.actor_group.name %>
            </.link>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Resource
          </:label>
          <:value>
            <.link
              navigate={~p"/#{@account}/resources/#{@policy.resource_id}"}
              class="text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @policy.resource.name %>
            </.link>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Created
          </:label>
          <:value>
            <%= pretty_print_date(@policy.inserted_at) %> by
            <.link
              navigate={~p"/#{@account}/actors/#{@policy.created_by_identity.actor.id}"}
              class="text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @policy.created_by_identity.actor.name %>
            </.link>
          </:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Logs
        </h1>
      </div>
    </div>
    <div class="relative overflow-x-auto">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <thead class="text-xs text-gray-900 uppercase dark:text-gray-400">
          <tr>
            <th scope="col" class="px-6 py-3">
              Authorized at
            </th>
            <th scope="col" class="px-6 py-3">
              Client
            </th>
            <th scope="col" class="px-6 py-3">
              User
            </th>
          </tr>
        </thead>
        <tbody>
          <tr class="bg-white dark:bg-gray-800">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              May 1, 2023 8:45p
            </th>
            <td class="px-6 py-4">
              <.link
                class="text-blue-600 dark:text-blue-500 hover:underline"
                navigate={~p"/#{@account}/clients/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
              >
                2425BD07A38D
              </.link>
            </td>
            <td class="px-6 py-4">
              <.link
                class="text-blue-600 dark:text-blue-500 hover:underline"
                navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
              >
                <%= "Thomas Eizinger <thomas@eizinger.io>" %>
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Delete Policy
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
