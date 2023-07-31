defmodule Web.GatewaysLive.Edit do
  use Web, :live_view

  alias Domain.Gateways

  def mount(%{"id" => id} = _params, _session, socket) do
    {:ok, gateway} = Gateways.fetch_gateway_by_id(id, socket.assigns.subject, preload: :group)
    {:ok, assign(socket, gateway: gateway)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/gateways"}>Gateways</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}"}>
        <%= @gateway.name_suffix %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing Gateway <code><%= @gateway.name_suffix %></code>
      </:title>
    </.header>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Gateway details</h2>
        <form action="#">
          <div class="grid gap-4 sm:grid-cols-1 sm:gap-6">
            <div>
              <.label for="gateway-name">
                Name
              </.label>
              <input
                type="text"
                name="gateway-name"
                id="gateway-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
                value={@gateway.name_suffix}
              />
            </div>
          </div>
          <.submit_button>
            Save
          </.submit_button>
        </form>
      </div>
    </section>
    """
  end
end
