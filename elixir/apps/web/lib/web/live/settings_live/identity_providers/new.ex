defmodule Web.SettingsLive.IdentityProviders.New do
  use Web, :live_view
  alias Domain.Auth

  def mount(_params, _session, socket) do
    {:ok, adapters} = Auth.list_provider_adapters()
    dbg(adapters)

    socket =
      socket
      |> assign(:form, %{})

    {:ok, socket,
     temporary_assigns: [
       adapters: adapters
     ]}
  end

  def handle_event("submit", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next)}
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

              <.adapter
                :for={{adapter, _module} <- @adapters}
                adapter={adapter}
                account={@subject.account}
              />
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

  def adapter(%{adapter: :google_workspace} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      name="Google Workspace"
      description="Authenticate users and synchronize users and groups with preconfigured Google Workspace connector."
    />
    """
  end

  def adapter(%{adapter: :openid_connect} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      name="OpenID Connect"
      description="Authenticate users with a generic OpenID Connect adapter and synchronize users and groups with just-in-time provisioning."
    />
    """
  end

  def adapter(%{adapter: :saml} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      name="SAML 2.0"
      description="Authenticate users with a custom SAML 2.0 adapter and synchronize users and groups with SCIM 2.0."
    />
    """
  end

  def adapter_item(assigns) do
    ~H"""
    <div>
      <div class="flex items-center mb-4">
        <input
          id={"idp-option-#{@adapter}"}
          type="radio"
          name="next"
          value={~p"/#{@account}/settings/identity_providers/new/#{@adapter}"}
          class={~w[
            w-4 h-4 border-gray-300
            focus:ring-2 focus:ring-blue-300
            dark:focus:ring-blue-600 dark:bg-gray-700 dark:border-gray-600
          ]}
          required
        />
        <label
          for={"idp-option-#{@adapter}"}
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
end
