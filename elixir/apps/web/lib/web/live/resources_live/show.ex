defmodule Web.ResourcesLive.Show do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Resources", path: ~p"/#{@subject.account}/resources"},
          %{
            label: "Engineering Jira",
            path: ~p"/#{@subject.account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Viewing Resource <code>Engineering Jira</code>
      </:title>
      <:actions>
        <.edit_button navigate={
          ~p"/#{@subject.account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
        }>
          Edit Resource
        </.edit_button>
      </:actions>
    </.section_header>
    <!-- Resource details -->
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
              Engineering Jira
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Address
            </th>
            <td class="px-6 py-4">
              jira.company.com
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Traffic restriction
            </th>
            <td class="px-6 py-4">
              Permit all
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
    <!-- Linked Gateways table -->
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Linked Gateways
        </h1>
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
              IP
            </th>
            <th scope="col" class="px-6 py-3">
              Status
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
                navigate={~p"/#{@subject.account}/gateways/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                aws-primary
              </.link>
            </th>
            <td class="px-6 py-4">
              <code class="block text-xs">201.45.66.101</code>
            </td>
            <td class="px-6 py-4">
              <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                Online
              </span>
            </td>
          </tr>
          <tr class="border-b dark:border-gray-700">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              <.link
                navigate={~p"/#{@subject.account}/gateways/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                aws-secondary
              </.link>
            </th>
            <td class="px-6 py-4">
              <code class="block text-xs">11.34.176.175</code>
            </td>
            <td class="px-6 py-4">
              <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                Online
              </span>
            </td>
          </tr>
          <tr class="border-b dark:border-gray-700">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              <.link
                navigate={~p"/#{@subject.account}/gateways/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                gcp-primary
              </.link>
            </th>
            <td class="px-6 py-4">
              <code class="block text-xs">45.11.23.17</code>
            </td>
            <td class="px-6 py-4">
              <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                Online
              </span>
            </td>
          </tr>
          <tr class="border-b dark:border-gray-700">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              <.link
                navigate={~p"/#{@subject.account}/gateways/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                gcp-secondary
              </.link>
            </th>
            <td class="px-6 py-4">
              <code class="block text-xs">80.113.105.104</code>
            </td>
            <td class="px-6 py-4">
              <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                Online
              </span>
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
          Delete Resource
        </.delete_button>
      </:actions>
    </.section_header>
    """
  end
end
