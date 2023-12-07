defmodule Web.Actors.New do
  use Web, :live_view
  import Web.Actors.Components

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:form, %{})

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/new"}>Add</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Add Actor
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">Choose type</h2>
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
              <.submit_button>
                Next: Create Actor
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("submit", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next)}
  end
end
