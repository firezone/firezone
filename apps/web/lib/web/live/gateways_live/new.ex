defmodule Web.GatewaysLive.New do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/"},
          %{label: "Gateways", path: ~p"/gateways"},
          %{label: "Add Gateway", path: ~p"/gateways/new"}
        ]} />
      </:breadcrumbs>
      <:title>
        Add a new gateway
      </:title>
    </.section_header>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Gateway details</h2>
        <form action="#">
          <div class="grid gap-4 sm:grid-cols-1 sm:gap-6">
            <div>
              <.label for="first-name">
                Name
              </.label>
              <input
                type="text"
                name="first-name"
                id="first-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
              />
            </div>
            <div>
              <.label>
                Select a deployment method
              </.label>
              <.button_group>
                <:first>
                  Docker
                </:first>
                <:last>
                  Systemd
                </:last>
              </.button_group>
            </div>
          </div>
          <.submit_button>
            Create
          </.submit_button>
        </form>
      </div>
    </section>
    """
  end
end
