defmodule Web.PoliciesLive.Show do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
        Engineering access to GitLab
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing Policy <code>Engineering access to GitLab</code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/policies/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}>
          Edit Policy
        </.edit_button>
      </:actions>
    </.header>
    <!-- Show Policy -->
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
              Engineering access to GitLab
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Group
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
              Resource
            </th>
            <td class="px-6 py-4">
              GitLab
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
                navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
              >
                Andrew Dryga
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Logs
        </h1>
      </div>
    </div>
    <div class="relative overflow-x-auto">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <thead class="text-xs text-gray-900 uppercase dark:text-gray-400">
          <tr>
            <th scope="col" class="px-6 py-3">
              Authorized at
            </th>
            <th scope="col" class="px-6 py-3">
              Device
            </th>
            <th scope="col" class="px-6 py-3">
              User
            </th>
          </tr>
        </thead>
        <tbody>
          <tr class="bg-white dark:bg-gray-800">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              May 1, 2023 8:45p
            </th>
            <td class="px-6 py-4">
              <.link
                class="text-blue-600 dark:text-blue-500 hover:underline"
                navigate={~p"/#{@account}/devices/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
              >
                2425BD07A38D
              </.link>
            </td>
            <td class="px-6 py-4">
              <.link
                class="text-blue-600 dark:text-blue-500 hover:underline"
                navigate={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
              >
                <%= "Thomas Eizinger <thomas@eizinger.io>" %>
              </.link>
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
          Delete Policy
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
