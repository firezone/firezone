defmodule Web.GroupsLive.Show do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <!-- Breadcrumbs -->
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/"},
          %{label: "Groups", path: ~p"/groups"},
          %{label: "Engineering", path: ~p"/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
        ]} />
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">Group details</h1>
      </div>
    </div>
    <!-- Group Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
        <div class="w-full md:w-auto flex flex-col md:flex-row space-y-2 md:space-y-0 items-stretch md:items-center justify-end md:space-x-3 flex-shrink-0">
          <.link
            navigate={~p"/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}
            class="flex items-center justify-center text-white bg-primary-700 hover:bg-primary-800 focus:ring-4 focus:ring-primary-300 font-medium rounded-lg text-sm px-4 py-2 dark:bg-primary-600 dark:hover:bg-primary-700 focus:outline-none dark:focus:ring-primary-800"
          >
            <.icon name="hero-pencil-solid" class="w-3.5 h-3.5 mr-2" /> Edit group
          </.link>
        </div>
      </div>
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
              Engineering
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Source
            </th>
            <td class="px-6 py-4">
              Created manually by
              <.link
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                navigate={~p"/users/BEE2202A-2598-401D-A6C1-8CC09FFB853A"}
              >
                Jamil Bou Kheir
              </.link>
              on May 3rd, 2023.
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Last active
            </th>
            <td class="px-6 py-4">
              1 hour ago
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <!-- Users table -->
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">Users</h1>
      </div>
    </div>

    <div class="relative overflow-x-auto">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <thead class="text-xs text-gray-900 uppercase dark:text-gray-400">
          <tr>
            <th scope="col" class="px-6 py-3">
              Name
            </th>
            <th scope="col" class="px-6 py-3">
              Identifiers
            </th>
          </tr>
        </thead>
        <tbody>
          <tr class="bg-white dark:bg-gray-800">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              <.link
                navigate={~p"/users/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                Bou Kheir, Jamil
              </.link>
            </th>
            <td class="px-6 py-4">
              <strong>email:</strong>jamil@firezone.dev,<strong>okta:</strong>jamil@firezone.dev
            </td>
          </tr>
          <tr class="border-b dark:border-gray-700">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              <.link
                navigate={~p"/users/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                Dryga, Andrew
              </.link>
            </th>
            <td class="px-6 py-4">
              <strong>email:</strong>a@firezone.dev,<strong>okta:</strong>andrew.dryga@firezone.dev
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
