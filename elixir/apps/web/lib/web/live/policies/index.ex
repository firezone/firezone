defmodule Web.PoliciesLive.Index do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        All Policies
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/policies/new"}>
          Add a new Policy
        </.add_button>
      </:actions>
    </.header>
    <!-- Policies table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
        <div class="w-full md:w-1/2">
          <form class="flex items-center">
            <label for="simple-search" class="sr-only">Search</label>
            <div class="relative w-full">
              <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
                <.icon name="hero-magnifying-glass" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
              </div>
              <input
                type="text"
                id="simple-search"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-500 focus:border-primary-500 block w-full pl-10 p-2 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                placeholder="Search"
              />
            </div>
          </form>
        </div>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
          <thead class="text-xs text-gray-700 uppercase bg-gray-50 dark:bg-gray-700 dark:text-gray-400">
            <tr>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Name
                  <a href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </a>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Group
                  <a href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </a>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Resource
                  <a href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </a>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <span class="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={~p"/#{@account}/policies/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Engineering access to Gitlab
                </.link>
              </th>
              <td class="px-4 py-3">
                <.link
                  class="inline-block"
                  navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                >
                  <span class="bg-gray-100 text-gray-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-gray-900 dark:text-gray-300">
                    Engineering
                  </span>
                </.link>
              </td>
              <td class="px-4 py-3">
                <.link
                  class="text-blue-600 dark:text-blue-500 hover:underline"
                  navigate={~p"/#{@account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                >
                  GitLab
                </.link>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <.link navigate="#" class="text-blue-600 dark:text-blue-500 hover:underline">
                  Delete
                </.link>
              </td>
            </tr>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={~p"/#{@account}/policies/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  IT access to Staging VPC
                </.link>
              </th>
              <td class="px-4 py-3">
                <.link
                  class="inline-block"
                  navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                >
                  <span class="bg-gray-100 text-gray-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-gray-900 dark:text-gray-300">
                    IT
                  </span>
                </.link>
              </td>
              <td class="px-4 py-3">
                <.link
                  class="text-blue-600 dark:text-blue-500 hover:underline"
                  navigate={~p"/#{@account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                >
                  Staging VPC
                </.link>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <.link navigate="#" class="text-blue-600 dark:text-blue-500 hover:underline">
                  Delete
                </.link>
              </td>
            </tr>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={~p"/#{@account}/policies/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Admin access to Jira
                </.link>
              </th>
              <td class="px-4 py-3">
                <.link
                  class="inline-block"
                  navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                >
                  <span class="bg-gray-100 text-gray-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-gray-900 dark:text-gray-300">
                    Admin
                  </span>
                </.link>
              </td>
              <td class="px-4 py-3">
                <.link
                  class="text-blue-600 dark:text-blue-500 hover:underline"
                  navigate={~p"/#{@account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                >
                  Jira
                </.link>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <.link navigate="#" class="text-blue-600 dark:text-blue-500 hover:underline">
                  Delete
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/gateways"} />
    </div>
    """
  end
end
