defmodule Web.SettingsLive.IdentityProviders.Index do
  use Web, :live_view
  alias Domain.{Auth, Accounts}

  def mount(%{"account_id" => account_id}, _session, socket) do
    with {:ok, account} <- Accounts.fetch_account_by_id(account_id),
         {:ok, providers} <- Auth.list_active_providers_for_account(account) do
      {:ok, socket,
       temporary_assigns: [
         account: account,
         providers: providers,
         page_title: "Identity Providers"
       ]}
    else
      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "Account not found.")
          |> redirect(to: ~p"/#{account_id}/")

        {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Identity Providers
      </:title>

      <:actions>
        <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
          Add Identity Provider
        </.add_button>
      </:actions>
    </.header>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.link
        class="text-blue-600 dark:text-blue-500 hover:underline"
        href="https://www.firezone.dev/docs/architecture/sso"
        target="_blank"
      >
        Read more about how SSO works in Firezone.
        <.icon name="hero-arrow-top-right-on-square" class="-ml-1 mb-3 w-3 h-3" />
      </.link>
    </p>
    <!-- Identity Providers Table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <div class="overflow-x-auto">
        <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
          <thead class="text-xs text-gray-700 uppercase bg-gray-50 dark:bg-gray-700 dark:text-gray-400">
            <tr>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Name
                  <.link href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </.link>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Type
                  <.link href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </.link>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Status
                  <.link href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </.link>
                </div>
              </th>
              <th scope="col" class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={
                    ~p"/#{@account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
                  }
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Okta
                </.link>
              </th>
              <td class="px-4 py-3">
                SAML
              </td>
              <td class="px-4 py-3">
                <div class="flex items-center">
                  <span class="w-3 h-3 bg-green-500 rounded-full"></span>
                  <span class="ml-3">
                    Synced
                    <.link
                      navigate={~p"/#{@account}/actors"}
                      class="text-blue-600 dark:text-blue-500 hover:underline"
                    >
                      17 users
                    </.link>
                    and
                    <.link
                      navigate={~p"/#{@account}/groups"}
                      class="text-blue-600 dark:text-blue-500 hover:underline"
                    >
                      8 groups
                    </.link>
                    47 minutes ago
                  </span>
                </div>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="provider-1-dropdown-button"
                  data-dropdown-toggle="provider-1-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="provider-1-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="provider-1-dropdown-button"
                  >
                    <li>
                      <.link
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Sync now
                      </.link>
                    </li>
                    <li>
                      <.link
                        navigate={
                          ~p"/#{@account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
                        }
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Edit
                      </.link>
                    </li>
                  </ul>
                  <div class="py-1">
                    <.link
                      href="#"
                      class="block py-2 px-4 text-sm text-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 dark:text-gray-200 dark:hover:text-white"
                    >
                      Delete
                    </.link>
                  </div>
                </div>
              </td>
            </tr>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={
                    ~p"/#{@account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
                  }
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Authentik
                </.link>
              </th>
              <td class="px-4 py-3">
                OIDC
              </td>
              <td class="px-4 py-3">
                <div class="flex items-center">
                  <span class="w-3 h-3 bg-green-500 rounded-full"></span>
                  <span class="ml-3">
                    Synced
                    <.link
                      class="text-blue-600 dark:text-blue-500 hover:underline"
                      navigate={~p"/#{@account}/actors"}
                    >
                      67 users
                    </.link>
                    and
                    <.link
                      class="text-blue-600 dark:text-blue-500 hover:underline"
                      navigate={~p"/#{@account}/groups"}
                    >
                      4 groups
                    </.link>
                    11 minutes ago
                  </span>
                </div>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="provider-2-dropdown-button"
                  data-dropdown-toggle="provider-2-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="provider-2-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="provider-2-dropdown-button"
                  >
                    <li>
                      <.link
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Sync now
                      </.link>
                    </li>
                    <li>
                      <.link
                        navigate={
                          ~p"/#{@account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
                        }
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Edit
                      </.link>
                    </li>
                  </ul>
                  <div class="py-1">
                    <a
                      href="#"
                      class="block py-2 px-4 text-sm text-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 dark:text-gray-200 dark:hover:text-white"
                    >
                      Delete
                    </a>
                  </div>
                </div>
              </td>
            </tr>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={
                    ~p"/#{@account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
                  }
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Google
                </.link>
              </th>
              <td class="px-4 py-3">
                Google Workspace
              </td>
              <td class="px-4 py-3">
                <div class="flex items-center">
                  <span class="w-3 h-3 bg-green-500 rounded-full"></span>
                  <span class="ml-3">
                    Synced
                    <.link
                      class="text-blue-600 dark:text-blue-500 hover:underline"
                      navigate={~p"/#{@account}/actors"}
                    >
                      221 users
                    </.link>
                    and
                    <.link
                      class="text-blue-600 dark:text-blue-500 hover:underline"
                      navigate={~p"/#{@account}/groups"}
                    >
                      14 groups
                    </.link>
                    57 minutes ago
                  </span>
                </div>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="provider-2-dropdown-button"
                  data-dropdown-toggle="provider-2-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="provider-2-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="provider-2-dropdown-button"
                  >
                    <li>
                      <.link
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Sync now
                      </.link>
                    </li>
                    <li>
                      <.link
                        navigate={
                          ~p"/#{@account}/settings/identity_providers/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
                        }
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Edit
                      </.link>
                    </li>
                  </ul>
                  <div class="py-1">
                    <a
                      href="#"
                      class="block py-2 px-4 text-sm text-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 dark:text-gray-200 dark:hover:text-white"
                    >
                      Delete
                    </a>
                  </div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
