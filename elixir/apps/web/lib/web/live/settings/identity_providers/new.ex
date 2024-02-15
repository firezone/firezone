defmodule Web.Settings.IdentityProviders.New do
  use Web, :live_view
  alias Domain.Auth

  def mount(_params, _session, socket) do
    {:ok, adapters} = Auth.list_provider_adapters()
    socket = assign(socket, form: %{}, adapters: adapters, page_title: "New Identity Provider")
    {:ok, socket}
  end

  def handle_event("submit", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/new"}>
        Create Identity Provider
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Add a new Identity Provider
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Choose type</h2>
          <.form id="identity-provider-type-form" for={@form} phx-submit="submit">
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset>
                <legend class="sr-only">Identity Provider Type</legend>

                <.adapter :for={{adapter, _module} <- @adapters} adapter={adapter} account={@account} />
              </fieldset>
            </div>
            <.submit_button>
              Next: Configure
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def adapter(%{adapter: :google_workspace} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      enterprise_feature={true}
      name="Google Workspace"
      description="Authenticate users and synchronize users and groups with a custom Google Workspace connector."
    />
    """
  end

  def adapter(%{adapter: :microsoft_entra} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      enterprise_feature={true}
      name="Microsoft Entra ID"
      description="Authenticate users and synchronize users and groups with a custom Microsoft Entra ID connector."
    />
    """
  end

  def adapter(%{adapter: :okta} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      enterprise_feature={true}
      name="Okta"
      description="Authenticate users and synchronize users and groups with a custom Okta connector."
    />
    """
  end

  def adapter(%{adapter: :openid_connect} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      name="OpenID Connect"
      description="Authenticate users with a universal OpenID Connect adapter and manager users and groups manually."
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

  attr :adapter, :any
  attr :account, :any
  attr :enterprise_feature, :boolean, default: false
  attr :name, :string
  attr :description, :string

  def adapter_item(assigns) do
    ~H"""
    <div>
      <div class="flex items-center mb-4">
        <input
          id={"idp-option-#{@adapter}"}
          type="radio"
          name="next"
          value={next_step_path(@adapter, @account)}
          class={~w[ w-4 h-4 border-neutral-300 ]}
          required
        />
        <.provider_icon adapter={@adapter} class="w-8 h-8 ml-4" />
        <label for={"idp-option-#{@adapter}"} class="block ml-2 text-lg text-neutral-900">
          <%= @name %>
        </label>
        <%= if @enterprise_feature do %>
          <.badge class="ml-2" type="primary" title="Feature available on the Enterprise plan">
            ENTERPRISE
          </.badge>
        <% end %>
      </div>
      <p class="ml-6 mb-6 text-sm text-neutral-500">
        <%= @description %>
      </p>
    </div>
    """
  end

  def next_step_path(:openid_connect, account) do
    ~p"/#{account}/settings/identity_providers/openid_connect/new"
  end

  def next_step_path(:google_workspace, account) do
    ~p"/#{account}/settings/identity_providers/google_workspace/new"
  end

  def next_step_path(:microsoft_entra, account) do
    ~p"/#{account}/settings/identity_providers/microsoft_entra/new"
  end

  def next_step_path(:okta, account) do
    ~p"/#{account}/settings/identity_providers/okta/new"
  end
end
