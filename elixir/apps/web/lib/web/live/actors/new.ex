defmodule Web.Actors.New do
  use Web, :live_view
  import Web.Actors.Components

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
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
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Choose type</h2>
          <.form id="identity-provider-type-form" for={%{}} phx-submit="submit">
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset>
                <legend class="sr-only">Choose Actor Type</legend>

                <ul class="grid w-full gap-6 md:grid-cols-2">
                  <li>
                    <.input
                      id="idp-option-user"
                      type="radio_button_group"
                      name="next"
                      value={next_step_path(:user, @account)}
                      checked={false}
                      required
                    />
                    <label for="idp-option-user" class={~w[
                    inline-flex items-center justify-between w-full
                    p-5 text-gray-500 bg-white border border-gray-200
                    rounded cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                      <div class="block">
                        <div class="w-full font-semibold mb-3">
                          <.icon name="hero-user" class="w-5 h-5 mr-1" /> User
                        </div>
                        <div class="w-full text-sm">
                          User accounts can sign in to the Firezone Client apps or to
                          the admin portal depending on their role.
                        </div>
                      </div>
                    </label>
                  </li>

                  <li>
                    <.input
                      id="idp-option-service_account"
                      type="radio_button_group"
                      name="next"
                      value={next_step_path(:service_account, @account)}
                      checked={false}
                      required
                    />
                    <label for="idp-option-service_account" class={~w[
                    inline-flex items-center justify-between w-full
                    p-5 text-gray-500 bg-white border border-gray-200
                    rounded cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                      <div class="block">
                        <div class="w-full font-semibold mb-3">
                          <.icon name="hero-server" class="w-5 h-5 mr-1" /> Service Account
                        </div>
                        <div class="w-full text-sm">
                          Service accounts are used to authenticate headless Clients on
                          machines where a user isn't physically present.
                        </div>
                      </div>
                    </label>
                  </li>
                </ul>
              </fieldset>
            </div>
            <.submit_button>
              Next: Actor Details
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
