defmodule Web.Settings.IdentityProviders.New do
  use Web, :live_view
  alias Domain.Auth

  def mount(_params, _session, socket) do
    adapters = Auth.list_user_provisioned_provider_adapters!(socket.assigns.account)

    socket =
      assign(socket,
        form: %{},
        adapters: adapters,
        page_title: "New Identity Provider"
      )

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

                <.adapter
                  :for={{adapter, opts} <- @adapters}
                  adapter={adapter}
                  opts={opts}
                  account={@account}
                />
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
      opts={@opts}
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
      opts={@opts}
      name="Microsoft Entra"
      description="Authenticate users and synchronize users and groups with a custom Microsoft Entra ID connector."
    />
    """
  end

  def adapter(%{adapter: :okta} = assigns) do
    ~H"""
    <.adapter_item
      adapter={@adapter}
      account={@account}
      opts={@opts}
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
      opts={@opts}
      name="OpenID Connect"
      description="Authenticate users with a universal OpenID Connect adapter and manager users and groups manually."
    />
    """
  end

  attr :adapter, :any
  attr :account, :any
  attr :opts, :any
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
          class={[
            "w-4 h-4 border-neutral-300",
            @opts[:enabled] == false && "cursor-not-allowed"
          ]}
          disabled={@opts[:enabled] == false}
          required
        />
        <.provider_icon adapter={@adapter} class="w-8 h-8 ml-4" />
        <label for={"idp-option-#{@adapter}"} class="block ml-2 text-lg text-neutral-900">
          <%= @name %>
        </label>

        <%= if @opts[:enabled] == false do %>
          <.link navigate={~p"/#{@account}/settings/billing"} class="ml-2 text-sm text-primary-500">
            <.badge class="ml-2" type="primary" title="Feature available on a higher pricing plan">
              UPGRADE TO UNLOCK
            </.badge>
          </.link>
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
