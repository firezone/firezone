defmodule Web.DevicesLive.Index do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/devices"}>Devices</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        All devices
      </:title>
    </.header>
    <!-- Devices Table -->
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
        <.button_group>
          <:first>
            All
          </:first>
          <:middle>
            Online
          </:middle>
          <:last>
            Archived
          </:last>
        </.button_group>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
          <thead class="text-xs text-gray-700 uppercase bg-gray-50 dark:bg-gray-700 dark:text-gray-400">
            <tr>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Client
                  <a href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </a>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  User
                  <a href="#">
                    <.icon name="hero-chevron-up-down-solid" class="w-4 h-4 ml-1" />
                  </a>
                </div>
              </th>
              <th scope="col" class="px-4 py-3">
                <div class="flex items-center">
                  Status
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
                  navigate={~p"/#{@account}/devices/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  v1.01 Linux
                </.link>
              </th>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  John Doe
                </.link>
              </td>

              <td class="px-4 py-3">
                <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                  Online
                </span>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="device-1-dropdown-button"
                  data-dropdown-toggle="device-1-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="device-1-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="device-1-dropdown-button"
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
                      <a
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Archive
                      </a>
                    </li>
                  </ul>
                </div>
              </td>
            </tr>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={~p"/#{@account}/devices/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  v1.01 iOS
                </.link>
              </th>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Steve Johnson
                </.link>
              </td>

              <td class="px-4 py-3">
                <span class="bg-gray-100 text-gray-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-gray-700 dark:text-gray-300">
                  Last seen 2 hours ago
                </span>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="device-2-dropdown-button"
                  data-dropdown-toggle="device-2-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="device-2-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="device-2-dropdown-button"
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
                      <a
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Archive
                      </a>
                    </li>
                  </ul>
                </div>
              </td>
            </tr>
            <tr class="border-b dark:border-gray-700">
              <th
                scope="row"
                class="px-4 py-3 font-medium text-gray-900 whitespace-nowrap dark:text-white"
              >
                <.link
                  navigate={~p"/#{@account}/devices/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  v1.01 macOS
                </.link>
              </th>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                >
                  Steinberg, Gabriel
                </.link>
              </td>

              <td class="px-4 py-3">
                <span class="bg-red-100 text-red-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-red-900 dark:text-red-300">
                  Archived 6 months ago
                </span>
              </td>
              <td class="px-4 py-3 flex items-center justify-end">
                <button
                  id="device-3-dropdown-button"
                  data-dropdown-toggle="device-3-dropdown"
                  class="inline-flex items-center p-0.5 text-sm font-medium text-center text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none dark:text-gray-400 dark:hover:text-gray-100"
                  type="button"
                >
                  <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                </button>
                <div
                  id="device-3-dropdown"
                  class="hidden z-10 w-44 bg-white rounded divide-y divide-gray-100 shadow dark:bg-gray-700 dark:divide-gray-600"
                >
                  <ul
                    class="py-1 text-sm text-gray-700 dark:text-gray-200"
                    aria-labelledby="device-3-dropdown-button"
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
                      <a
                        href="#"
                        class="block py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
                      >
                        Archive
                      </a>
                    </li>
                  </ul>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/devices"} />
    </div>
    """
  end
end
