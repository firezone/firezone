defmodule Web.SettingsLive.IdentityProviders.Show do
  use Web, :live_view
  alias Phoenix.LiveView.JS

  def toggle_scim_token(js \\ %JS{}) do
    js
    |> JS.toggle(to: "#visible-token")
    |> JS.toggle(to: "#hidden-token")
  end

  def render(assigns) do
    assigns =
      assign(assigns, identity_provider: %{scim_token: "DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"})

    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Identity Providers", path: ~p"/#{@subject.account}/settings/identity_providers"},
          %{
            label: "Okta",
            path:
              ~p"/#{@subject.account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Viewing Identity Provider <code>Okta</code>
      </:title>
      <:actions>
        <.edit_button navigate={
          ~p"/#{@subject.account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
        }>
          Edit Identity Provider
        </.edit_button>
      </:actions>
    </.section_header>
    <!-- Identity Provider details -->
    <.section_header>
      <:title>Details</:title>
    </.section_header>
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
              Okta
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
              SAML 2.0
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Sign requests
            </th>
            <td class="px-6 py-4">
              Yes
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Sign metadata
            </th>
            <td class="px-6 py-4">
              Yes
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Require signed assertions
            </th>
            <td class="px-6 py-4">
              Yes
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Require signed envelopes
            </th>
            <td class="px-6 py-4">
              Yes
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Base URL
            </th>
            <td class="px-6 py-4">
              Yes
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
              4/15/22 12:32 PM by
              <.link
                class="text-blue-600 hover:underline"
                navigate={~p"/#{@subject.account}/users/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
              >
                Andrew Dryga
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <!-- Provisioning details -->
    <.section_header>
      <:title>Provisioning</:title>
    </.section_header>
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <tbody>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Type
            </th>
            <td class="px-6 py-4">
              SCIM 2.0
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Endpoint
            </th>
            <td class="px-6 py-4">
              <div class="flex items-center">
                <button
                  phx-click={JS.dispatch("phx:copy", to: "#endpoint-value")}
                  title="Copy Endpoint"
                  class="text-blue-600 dark:text-blue-500"
                >
                  <.icon name="hero-document-duplicate" class="w-5 h-5 mr-1" />
                </button>
                <code id="endpoint-value" data-copy={url(~p"/#{@subject.account}/scim/v2")}>
                  <%= url(~p"/#{@subject.account}/scim/v2") %>
                </code>
              </div>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Token
            </th>
            <td class="px-6 py-4">
              <div class="flex items-center">
                <button
                  phx-click={JS.dispatch("phx:copy", to: "#visible-token")}
                  title="Copy SCIM token"
                  class="text-blue-600 dark:text-blue-500"
                >
                  <.icon name="hero-document-duplicate" class="w-5 h-5 mr-1" />
                </button>
                <button
                  phx-click={toggle_scim_token()}
                  title="Show SCIM token"
                  class="text-blue-600 dark:text-blue-500"
                >
                  <.icon name="hero-eye" class="w-5 h-5 mr-1" />
                </button>

                <span id="hidden-token">
                  •••••••••••••••••••••••••••••••••••••••••••••
                </span>
                <span
                  id="visible-token"
                  style="display: none"
                  data-copy={@identity_provider.scim_token}
                >
                  <code><%= @identity_provider.scim_token %></code>
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <.section_header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Delete Identity Provider
        </.delete_button>
      </:actions>
    </.section_header>
    """
  end
end
