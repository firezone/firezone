defmodule Web.Actors.New do
  use Web, :live_view

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:form, %{})

    {:ok, socket}
  end

  def handle_event("submit", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/new"}>Add</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Add a new Actor
      </:title>
    </.header>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Choose type</h2>
        <.form id="identity-provider-type-form" for={@form} phx-submit="submit">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <fieldset>
              <legend class="sr-only">Choose Actor Type</legend>

              <.option
                account={@account}
                type={:user}
                name="User"
                description="Admin or regular user accounts can be used to log in to Firezone and access private resources."
              />
              <.option
                account={@account}
                type={:service_account}
                name="Service Account"
                description="Service accounts can be used for headless clients or to access Firezone APIs."
              />
            </fieldset>
          </div>
          <div class="flex justify-end items-center space-x-4">
            <button
              type="submit"
              class={[
                "text-white bg-primary-700 hover:bg-primary-800",
                "focus:ring-4 focus:outline-none focus:ring-primary-300",
                "font-medium rounded-lg text-sm px-5 py-2.5 text-center",
                "dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800"
              ]}
            >
              Next: Create Actor
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  def option(assigns) do
    ~H"""
    <div>
      <div class="flex items-center mb-4">
        <input
          id={"idp-option-#{@type}"}
          type="radio"
          name="next"
          value={next_step_path(@type, @account)}
          class={~w[
            w-4 h-4 border-gray-300
            focus:ring-2 focus:ring-blue-300
            dark:focus:ring-blue-600 dark:bg-gray-700 dark:border-gray-600
          ]}
          required
        />
        <label
          for={"idp-option-#{@type}"}
          class="block ml-2 text-lg font-medium text-gray-900 dark:text-gray-300"
        >
          <%= @name %>
        </label>
      </div>
      <p class="ml-6 mb-6 text-sm text-gray-500 dark:text-gray-400">
        <%= @description %>
      </p>
    </div>
    """
  end

  def next_step_path(:service_account, account) do
    ~p"/#{account}/actors/service_accounts/new"
  end

  def next_step_path(_other, account) do
    ~p"/#{account}/actors/users/new"
  end
end
