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
      <:title>{@page_title}</:title>
      <:help>
        Set up SSO authentication using your own identity provider. Directory sync
        also available for certain providers. <br /> Learn more about
        <.website_link path="/kb/authenticate/oidc">SSO authentication</.website_link>
        and
        <.website_link path="/kb/authenticate/directory-sync">directory sync</.website_link>
        in our docs.
      </:help>
      <:content>
        <div class="container mx-auto">
          <div class="max-w-sm mb-8 mx-auto">
            <div class="flex flex-col gap-4">
              <%= for {adapter, opts} <- @adapters, opts[:sync] == true do %>
                <.provider_card adapter={adapter} opts={opts} account={@account} />
              <% end %>
              <%= for {adapter, opts} <- @adapters, opts[:sync] == false do %>
                <.provider_card adapter={adapter} opts={opts} account={@account} />
              <% end %>
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
        "border border-neutral-200"
      ]}
      phx-click="next_step"
      phx-value-next={@adapter}
    >
      <div class="w-full">
        <.provider_icon adapter={@adapter} class="w-10 h-10 inline-block mr-2" />
        <span class="inline-block">{pretty_print_provider(@adapter)}</span>
      </div>

      <div :if={@opts[:sync] == true} class="w-1/2 flex justify-end">
        <.icon name="hero-arrow-path" class="w-5 h-5 text-neutral-400" />
      </div>
    </div>
    """
  end

  def next_step_path("openid_connect", account) do
    ~p"/#{account}/settings/identity_providers/openid_connect/new"
  end

  def next_step_path("google_workspace" = provider, account) do
    if Domain.Accounts.idp_sync_enabled?(account) do
      ~p"/#{account}/settings/identity_providers/google_workspace/new"
    else
      ~p"/#{account}/settings/identity_providers/openid_connect/new?provider=#{provider}"
    end
  end

  def next_step_path("microsoft_entra" = provider, account) do
    if Domain.Accounts.idp_sync_enabled?(account) do
      ~p"/#{account}/settings/identity_providers/microsoft_entra/new"
    else
      ~p"/#{account}/settings/identity_providers/openid_connect/new?provider=#{provider}"
    end
  end

  def next_step_path("okta" = provider, account) do
    if Domain.Accounts.idp_sync_enabled?(account) do
      ~p"/#{account}/settings/identity_providers/okta/new"
    else
      ~p"/#{account}/settings/identity_providers/openid_connect/new?provider=#{provider}"
    end
  end

  def next_step_path("jumpcloud" = provider, account) do
    if Domain.Accounts.idp_sync_enabled?(account) do
      ~p"/#{account}/settings/identity_providers/jumpcloud/new"
    else
      ~p"/#{account}/settings/identity_providers/openid_connect/new?provider=#{provider}"
    end
  end

  def next_step_path("mock", account) do
    ~p"/#{account}/settings/identity_providers/mock/new"
  end

  def pretty_print_provider(adapter) do
    case adapter do
      :openid_connect -> "OpenID Connect"
      :google_workspace -> "Google Workspace"
      :microsoft_entra -> "Microsoft EntraID"
      :okta -> "Okta"
      :jumpcloud -> "JumpCloud"
      :mock -> "Mock"
    end
  end
end
