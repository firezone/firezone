defmodule Web.Settings.IdentityProviders.New do
  use Web, :live_view
  alias Domain.Auth

  def mount(_params, _session, socket) do
    adapters = Auth.all_user_provisioned_provider_adapters!(socket.assigns.account)

    socket =
      assign(socket,
        page_title: "New Identity Provider",
        adapters: adapters
      )

    {:ok, socket}
  end

  def handle_event("submit", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next)}
  end

  def handle_event("next_step", %{"next" => next}, socket) do
    {:noreply, push_navigate(socket, to: next_step_path(next, socket.assigns.account))}
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
        <div class="container mx-auto">
          <div class="max-w-4xl mb-8 mx-auto">
            <div class="flex flex-col lg:flex-row">
              <!-- Authentication only providers -->
              <div class="lg:w-1/2 px-4">
                <div class="py-4">
                  <h3 class="text-lg mb-4 underline">Authentication</h3>
                  <div class="text-sm text-neutral-500">
                    These providers only provide authentication.  All user and group management must be done manually in Firezone.
                  </div>
                </div>
                <div class="flex flex-col gap-6">
                  <%= for {adapter, opts} <- @adapters, opts[:sync] == false do %>
                    <.provider_card adapter={adapter} opts={opts} account={@account} />
                  <% end %>
                </div>
              </div>
              <!-- Authentication and Sync providers -->
              <div class="lg:w-1/2 px-4">
                <div class="py-4">
                  <h3 class="text-lg mb-4 underline">Authentication and Directory Sync</h3>
                  <div class="text-sm text-neutral-500">
                    These custom providers allow both authentication and directory sync. Only available for enterprise plans.
                  </div>
                </div>
                <div class="flex flex-col gap-6">
                  <%= for {adapter, opts} <- @adapters, opts[:sync] == true do %>
                    <.provider_card adapter={adapter} opts={opts} account={@account} />
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  attr :adapter, :any
  attr :account, :any
  attr :opts, :any

  def provider_card(assigns) do
    ~H"""
    <div
      id={"idp-option-#{@adapter}"}
      class={[
        "component bg-white rounded",
        "px-4 py-2 flex items-center",
        "cursor-pointer hover:bg-gray-50",
        "border border-neutral-100",
        @opts[:enabled] == false && "opacity-40"
      ]}
      phx-click="next_step"
      phx-value-next={(@opts[:enabled] == false && "billing") || @adapter}
    >
      <.provider_icon adapter={@adapter} class="w-10 h-10 inline-block mr-2" />
      <span class="inline-block"><%= pretty_print_provider(@adapter) %></span>

      <div :if={@opts[:enabled] == false} class="w-full flex justify-end">
        <.link navigate={~p"/#{@account}/settings/billing"} class="text-sm text-primary-500">
          <.badge type="primary" title="Feature available on a higher pricing plan">
            <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
          </.badge>
        </.link>
      </div>
    </div>
    """
  end

  def next_step_path("openid_connect", account) do
    ~p"/#{account}/settings/identity_providers/openid_connect/new"
  end

  def next_step_path("google_workspace", account) do
    ~p"/#{account}/settings/identity_providers/google_workspace/new"
  end

  def next_step_path("microsoft_entra", account) do
    ~p"/#{account}/settings/identity_providers/microsoft_entra/new"
  end

  def next_step_path("okta", account) do
    ~p"/#{account}/settings/identity_providers/okta/new"
  end

  def next_step_path("jumpcloud", account) do
    ~p"/#{account}/settings/identity_providers/jumpcloud/new"
  end

  def next_step_path("billing", account) do
    ~p"/#{account}/settings/billing"
  end

  def pretty_print_provider(adapter) do
    case adapter do
      :openid_connect -> "OpenID Connect"
      :google_workspace -> "Google Workspace"
      :microsoft_entra -> "Microsoft EntraID"
      :okta -> "Okta"
      :jumpcloud -> "JumpCloud"
    end
  end
end
