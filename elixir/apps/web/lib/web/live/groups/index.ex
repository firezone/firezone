defmodule Web.GroupsLive.Index do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
    </.breadcrumbs>

    <.header>
      <:title>
        All groups
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/groups/new"}>
          Add a new group
        </.add_button>
      </:actions>
    </.header>
    <!-- Groups Table -->
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
                required=""
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
                  Source
                  <a href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </a>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Impact
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
                  navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Engineering
                </.link>
              </th>
              <td class="px-4 py-3">
                Created manually on May 1st, 2023
              </td>
              <td class="px-4 py-3">
                <strong>1 user</strong> with access to <strong>1 resource</strong>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="user-1-dropdown-button"
                  data-dropdown-toggle="user-1-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="user-1-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="user-1-dropdown-button"
                  >
                    <li>
                      <a
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Show
                      </a>
                    </li>
                    <li>
                      <.link
                        navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}
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
                  navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  DevOps
                </.link>
              </th>
              <td class="px-4 py-3">
                Synced from <strong>Azure Active Directory</strong> 1 hour ago
              </td>

              <td class="px-4 py-3">
                <strong>17 users</strong> with access to <strong>8 resources</strong>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="user-2-dropdown-button"
                  data-dropdown-toggle="user-2-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="user-2-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="user-2-dropdown-button"
                  >
                    <li>
                      <a
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Show
                      </a>
                    </li>
                    <li>
                      <span class="block py-2 px-4 text-gray-400">
                        Edit disabled
                      </span>
                    </li>
                  </ul>
                  <div class="py-1">
                    <span class="block py-2 px-4 text-gray-400">
                      Delete disabled
                    </span>
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
                  navigate={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Human Resources
                </.link>
              </th>
              <td class="px-4 py-3">
                Synced from <strong>Okta</strong> 17 minutes ago
              </td>
              <td class="px-4 py-3">
                <strong>25 users</strong> with access to <strong>11 resources</strong>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="user-3-dropdown-button"
                  data-dropdown-toggle="user-3-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="user-3-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="user-3-dropdown-button"
                  >
                    <li>
                      <a
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Show
                      </a>
                    </li>
                    <li>
                      <span class="block py-2 px-4 text-gray-400">
                        Edit disabled
                      </span>
                    </li>
                  </ul>
                  <div class="py-1">
                    <span class="block py-2 px-4 text-gray-400">
                      Delete disabled
                    </span>
                  </div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/groups"} />
    </div>
    """
  end
end
