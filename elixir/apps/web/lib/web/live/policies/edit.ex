defmodule Web.Policies.Edit do
  use Web, :live_view

  alias Domain.Policies

  def mount(%{"id" => id} = _params, _session, socket) do
    with {:ok, policy} <- Policies.fetch_policy_by_id(id, socket.assigns.subject) do
      {:ok, assign(socket, policy: policy)}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <%= @policy.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Edit Policy <code><%= @policy.name %></code>
      </:title>
    </.header>
    <!-- Edit Policy -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit Policy details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="name">
                Name
              </.label>
              <.input
                autocomplete="off"
                type="text"
                name="name"
                id="policy-name"
                placeholder="Name of Policy"
                value={@policy.name}
                required
              />
            </div>
          </div>
          <div class="flex items-center space-x-4">
            <.button type="submit" class="btn btn-primary">
              Save
            </.button>
          </div>
        </form>
      </div>
    </section>
    """
  end
end
