defmodule Web.Settings.IdentityProviders.SAML.Show do
  use Web, :live_view
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <-
           Auth.fetch_active_provider_by_id(provider_id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
           ) do
      {:ok, assign(socket, provider: provider)}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>

      <.breadcrumb path={
        ~p"/#{@account}/settings/identity_providers/saml/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
      }>
        <%= @provider.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Viewing Identity Provider <code><%= @provider.name %></code>
      </:title>
      <:action>
        <.edit_button navigate={
          ~p"/#{@account}/settings/identity_providers/saml/#{@provider.id}/edit"
        }>
          Edit Identity Provider
        </.edit_button>
      </:action>

      <:content>
        <.header>
          <:title>Details</:title>
        </.header>

        <.flash_group flash={@flash} />

        <div class="bg-white overflow-hidden">
          <table class="w-full text-sm text-left text-neutral-500">
            <tbody>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Name
                </th>
                <td class="px-6 py-4">
                  <%= @provider.name %>
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Type
                </th>
                <td class="px-6 py-4">
                  SAML 2.0
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Sign requests
                </th>
                <td class="px-6 py-4">
                  Yes
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Sign metadata
                </th>
                <td class="px-6 py-4">
                  Yes
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Require signed assertions
                </th>
                <td class="px-6 py-4">
                  Yes
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Require signed envelopes
                </th>
                <td class="px-6 py-4">
                  Yes
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Base URL
                </th>
                <td class="px-6 py-4">
                  Yes
                </td>
              </tr>
              <tr class="border-b border-neutral-200">
                <th
                  scope="row"
                  class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
                >
                  Created
                </th>
                <td class="px-6 py-4">
                  <.created_by account={@account} schema={@provider} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </:content>
    </.section>
    <.section>
      <:title>
        Danger zone
      </:title>
      <:action>
        <.delete_button
          data-confirm="Are you sure want to delete this provider along with all related data?"
          phx-click="delete"
        >
          Delete Identity Provider
        </.delete_button>
      </:action>
      <:content></:content>
    </.section>
    """
  end

  def handle_event("delete", _params, socket) do
    {:ok, _provider} = Auth.delete_provider(socket.assigns.provider, socket.assigns.subject)

    {:noreply,
     push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/identity_providers")}
  end
end
