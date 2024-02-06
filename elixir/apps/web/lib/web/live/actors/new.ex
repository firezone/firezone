defmodule Web.Actors.New do
  use Web, :live_view
  import Web.Actors.Components

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        form: %{},
        page_title: "New Actor"
      )

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
          <h2 class="mb-4 text-xl text-neutral-900">Choose type</h2>
          <.form id="identity-provider-type-form" for={@form} phx-submit="submit">
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset>
                <legend class="sr-only">Choose Actor Type</legend>

                <.option
                  account={@account}
                  type={:user}
                  name="User"
                  description="Admin or regular user accounts can be used to sign in to Firezone and access private resources."
                />
                <.option
                  account={@account}
                  type={:service_account}
                  name="Service Account"
                  description="Service accounts can be used for headless clients or to access Firezone APIs."
                />
              </fieldset>
            </div>
            <.submit_button>
              Next: Create Actor
            </.submit_button>
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
