defmodule Web.SettingsLive.IdentityProviders.New do
  use Web, :live_view

  def handle_event("submit", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next)}
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :form, %{})}
  end

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Identity Providers", path: ~p"/#{@subject.account}/settings/identity_providers"},
          %{
            label: "Add Identity Provider",
            path: ~p"/#{@subject.account}/settings/identity_providers/new"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Add a new Identity Provider
      </:title>
    </.section_header>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Choose type</h2>
        <.form id="identity-provider-type-form" for={@form} phx-submit="submit">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <fieldset>
              <legend class="sr-only">Identity Provider Type</legend>

              <div>
                <div class="flex items-center mb-2">
                  <input
                    id="idp-option-1"
                    type="radio"
                    name="next"
                    value={~p"/#{@subject.account}/settings/identity_providers/new/#"}
                    class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:focus:bg-blue-600 dark:bg-gray-700 dark:border-gray-600"
                    required
                  />
                  <label
                    for="idp-option-1"
                    class="block ml-2 text-md font-medium text-gray-900 dark:text-gray-300"
                  >
                    Google Workspace
                  </label>
                </div>
                <p class="ml-6 mb-6 text-sm text-gray-500 dark:text-gray-400">
                  Authenticate users and synchronize users and groups with preconfigured Google Workspace connector.
                </p>
              </div>

              <div>
                <div class="flex items-center mb-2">
                  <input
                    id="idp-option-2"
                    type="radio"
                    name="next"
                    value={~p"/#{@subject.account}/settings/identity_providers/new/oidc"}
                    class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:focus:bg-blue-600 dark:bg-gray-700 dark:border-gray-600"
                    required
                  />
                  <label
                    for="idp-option-2"
                    class="block ml-2 text-lg font-medium text-gray-900 dark:text-gray-300"
                  >
                    OIDC
                  </label>
                  <p class="ml-2 text-sm text-gray-500 dark:text-gray-400"></p>
                </div>
                <p class="ml-6 mb-6 text-sm text-gray-500 dark:text-gray-400">
                  Authenticate users with a custom OIDC adapter and synchronize users and groups with just-in-time provisioning.
                </p>
              </div>

              <div>
                <div class="flex items-center mb-4">
                  <input
                    id="idp-option-3"
                    type="radio"
                    name="next"
                    value={~p"/#{@subject.account}/settings/identity_providers/new/saml"}
                    class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:bg-gray-700 dark:border-gray-600"
                    required
                  />
                  <label
                    for="idp-option-3"
                    class="block ml-2 text-lg font-medium text-gray-900 dark:text-gray-300"
                  >
                    SAML 2.0
                  </label>
                </div>
                <p class="ml-6 mb-6 text-sm text-gray-500 dark:text-gray-400">
                  Authenticate users with a custom SAML 2.0 adapter and synchronize users and groups with SCIM 2.0.
                </p>
              </div>
            </fieldset>
          </div>
          <div class="flex justify-end items-center space-x-4">
            <button
              type="submit"
              class="text-white bg-primary-700 hover:bg-primary-800 focus:ring-4 focus:outline-none focus:ring-primary-300 font-medium rounded-lg text-sm px-5 py-2.5 text-center dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800"
            >
              Next: Configure
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end
end
