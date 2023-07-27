defmodule Web.SettingsLive.IdentityProviders.OpenIDConnect.Show do
  use Web, :live_view
  import Web.SettingsLive.IdentityProviders.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <-
           Auth.fetch_provider_by_id(provider_id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
           ) do
      {:ok, assign(socket, provider: provider)}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _provider} = Auth.delete_provider(socket.assigns.provider, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/settings/identity_providers")}
  end

  def handle_event("enable", _params, socket) do
    attrs = %{disabled_at: nil}
    {:ok, provider} = Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject)

    {:ok, provider} =
      Auth.fetch_provider_by_id(provider.id, socket.assigns.subject,
        preload: [created_by_identity: [:actor]]
      )

    {:noreply, assign(socket, provider: provider)}
  end

  def handle_event("disable", _params, socket) do
    attrs = %{disabled_at: DateTime.utc_now()}
    {:ok, provider} = Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject)

    {:ok, provider} =
      Auth.fetch_provider_by_id(provider.id, socket.assigns.subject,
        preload: [created_by_identity: [:actor]]
      )

    {:noreply, assign(socket, provider: provider)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>

      <.breadcrumb path={
        ~p"/#{@account}/settings/identity_providers/openid_connect//DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
      }>
        <%= @provider.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing Identity Provider <code><%= @provider.name %></code>
      </:title>
      <:actions>
        <.edit_button navigate={
          ~p"/#{@account}/settings/identity_providers/openid_connect/#{@provider.id}/edit"
        }>
          Edit Identity Provider
        </.edit_button>
        <.button :if={not is_nil(@provider.disabled_at)} phx-click="enable">
          Enable Identity Provider
        </.button>
        <.button
          :if={is_nil(@provider.disabled_at)}
          phx-click="disable"
          data-confirm="Are you sure want to disable this provider?"
        >
          Disable Identity Provider
        </.button>
        <.button navigate={
          ~p"/#{@provider.account_id}/settings/identity_providers/openid_connect/#{@provider}/redirect"
        }>
          Reconnect Identity Provider
        </.button>
      </:actions>
    </.header>
    <!-- Identity Provider details -->
    <.header>
      <:title>Details</:title>
    </.header>

    <.flash_group flash={@flash} />

    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <tbody>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Name
            </th>
            <td class="px-6 py-4">
              <%= @provider.name %>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Status
            </th>
            <td class="px-6 py-4">
              <.status provider={@provider} />
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Type
            </th>
            <td class="px-6 py-4">
              OpenID Connect
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Response Type
            </th>
            <td class="px-6 py-4">
              <%= @provider.adapter_config["response_type"] %>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Scope
            </th>
            <td class="px-6 py-4">
              <%= @provider.adapter_config["scope"] %>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Client ID
            </th>
            <td class="px-6 py-4">
              <%= @provider.adapter_config["client_id"] %>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Discovery URL
            </th>
            <td class="px-6 py-4">
              <a href={@provider.adapter_config["discovery_document_uri"]} target="_blank">
                <%= @provider.adapter_config["discovery_document_uri"] %>
                <.icon name="hero-arrow-top-right-on-square" class="relative bottom-1 w-3 h-3" />
              </a>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Created
            </th>
            <td class="px-6 py-4">
              <.datetime datetime={@provider.inserted_at} /> by <.owner schema={@provider} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button
          data-confirm="Are you sure want to delete this provider along with all related data?"
          phx-click="delete"
        >
          Delete Identity Provider
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
