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
        <.add_button navigate={~p"/#{@account}/policies/new"}>Add Policy</.add_button>
      </:actions>
    </.header>
    <!-- Policies table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.table id="policies" rows={@policies} row_id={&"policies-#{&1.id}"}>
        <:col :let={policy} label="ID">
          <.link
            navigate={~p"/#{@account}/policies/#{policy}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= policy.id %>
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
      </.table>
    </div>
    """
  end
end
