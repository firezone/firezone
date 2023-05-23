defmodule Web.UsersLive.Show do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <!-- Breadcrumbs -->
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/"},
          %{label: "Users", path: ~p"/users"},
          %{label: "Bou Kheir, Jamil", path: ~p"/users/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
        ]} />
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">User details</h1>
      </div>
    </div>
    <!-- User Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
        <div class="w-full md:w-auto flex flex-col md:flex-row space-y-2 md:space-y-0 items-stretch md:items-center justify-end md:space-x-3 flex-shrink-0">
          <.edit_button navigate={~p"/users/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}>
            Edit user
          </.edit_button>
        </div>
      </div>
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <tbody>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              First name
            </th>
            <td class="px-6 py-4">
              Steve
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Last name
            </th>
            <td class="px-6 py-4">
              Johnson
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
              Manually created by
              <a href="#" class="text-blue-600 hover:underline">Jamil Bou Kheir</a>
              on May 3rd, 2023.
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Email
            </th>
            <td class="px-6 py-4">
              steve@tesla.com <span class="text-gray-400">- Verified</span>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Role
            </th>
            <td class="px-6 py-4">
              Admin
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Groups
            </th>
            <td class="px-6 py-4">
              <.link
                navigate={~p"/groups/55DDA8CB-69A7-48FC-9048-639021C205A2"}
                class="text-blue-600 hover:underline"
              >
                Engineering
              </.link>
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
    """
  end
end
