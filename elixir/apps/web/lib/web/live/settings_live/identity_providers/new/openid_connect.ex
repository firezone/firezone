defmodule Web.SettingsLive.IdentityProviders.New.OpenIDConnect do
  use Web, :live_view
  import Web.SettingsLive.IdentityProviders.New.Components

  # TODO: Use a changeset for this
  @form_initializer %{
    "type" => "openid-connect",
    "scopes" => "openid profile email offline_access",
    "provisioning_strategy" => "jit",
    "jit_user_filter_type" => "email_allowlist",
    "jit_extract_groups" => "false"
  }

  def mount(_params, _session, socket) do
    changeset = Auth.Adapters.socket() = assign(socket, form: to_form(@form_initializer))
    {:ok, socket}
  end

  def handle_event("change", params, socket) do
    # TODO: Validations
    # changeset = ProvisioningStrategies.changeset(%ProvisioningStrategy{}, params)

    {:noreply, assign(socket, form: to_form(params))}
  end

  def handle_event("submit", _params, socket) do
    # TODO: Create identity provider
    idp = %{id: "DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}

    {:noreply,
     push_navigate(socket,
       to: ~p"/#{socket.assigns.subject.account}/settings/identity_providers/#{idp.id}"
     )}
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
          },
          %{
            label: "OpenID Connect",
            path: ~p"/#{@subject.account}/settings/identity_providers/new/openid_connect"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Add a new OpenID Connect Identity Provider
      </:title>
    </.section_header>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <.form for={@form} id="openid-connect-form" phx-change="change" phx-submit="submit">
          <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">
            Client configuration
          </h2>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input
                label="Name"
                autocomplete="off"
                field={@form[:name]}
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                placeholder="Name this identity provider"
                required
              />
              <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                A friendly name for this identity provider. This will be displayed to end-users.
              </p>
            </div>

            <div>
              <.input
                label="Scopes"
                autocomplete="off"
                field={@form[:scopes]}
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                placeholder="OpenID Connect scopes to request"
                required
              />
              <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                A space-delimited list of scopes to request from your identity provider. In most cases you shouldn't need to change this.
              </p>
            </div>

            <div>
              <.input
                label="Client ID"
                autocomplete="off"
                field={@form[:client_id]}
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required
              />
            </div>
            <div>
              <.input
                label="Client secret"
                autocomplete="off"
                field={@form[:client_secret]}
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required
              />
            </div>
            <div>
              <.input
                label="Discovery URI"
                autocomplete="off"
                field={@form[:discovery_uri]}
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required
              />
            </div>
          </div>

          <.provisioning_strategy_form form={@form} />

          <div class="flex justify-end items-center space-x-4">
            <button
              type="submit"
              class="text-white bg-primary-700 hover:bg-primary-800 focus:ring-4 focus:outline-none focus:ring-primary-300 font-medium rounded-lg text-sm px-5 py-2.5 text-center dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800"
            >
              Create Identity Provider
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end
end
