defmodule Web.UsersLive.Show do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Users</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
        Jamil Bou Kheir
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing User <code>Bou Kheir, Jamil</code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}>
          Edit user
        </.edit_button>
      </:actions>
    </.header>
    <!-- User Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
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
                navigate={~p"/#{@account}/groups/55DDA8CB-69A7-48FC-9048-639021C205A2"}
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

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Delete user
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
