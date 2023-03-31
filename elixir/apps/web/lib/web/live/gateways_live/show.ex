defmodule Web.GatewaysLive.Show do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Gateways", path: ~p"/#{@subject.account}/gateways"},
          %{
            label: "gcp-primary",
            path: ~p"/#{@subject.account}/gateways/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Viewing Gateway <code>gcp-primary</code>
      </:title>
      <:actions>
        <.edit_button navigate={
          ~p"/#{@subject.account}/gateways/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
        }>
          Edit Gateway
        </.edit_button>
      </:actions>
    </.section_header>
    <!-- Gateway details -->
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
              gcp-primary
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Connectivity
            </th>
            <td class="px-6 py-4">
              Peer to Peer
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Status
            </th>
            <td class="px-6 py-4">
              Online
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Location
            </th>
            <td class="px-6 py-4">
              San Jose, CA
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Last seen
            </th>
            <td class="px-6 py-4">
              1 hour ago in San Francisco, CA
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Remote IPv4
            </th>
            <td class="px-6 py-4">
              <code>69.100.123.11</code>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Remote IPv6
            </th>
            <td class="px-6 py-4">
              <code>2001:0db8:85a3:0000:0000:8a2e:0370:7334</code>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Transfer
            </th>
            <td class="px-6 py-4">
              4.43 GB up, 1.23 GB down
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Gateway version
            </th>
            <td class="px-6 py-4">
              v1.01 for Linux/x86_64
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              OS version
            </th>
            <td class="px-6 py-4">
              Linux 5.10.25-1-MANJARO x86_64
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Deployment method
            </th>
            <td class="px-6 py-4">
              Docker
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <!-- Linked Resources table -->
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Linked Resources
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
              Address
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
                navigate={~p"/#{@subject.account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                Engineering GitLab
              </.link>
            </th>
            <td class="px-6 py-4">
              gitlab.company.com
            </td>
          </tr>
          <tr class="border-b dark:border-gray-700">
            <th
              scope="row"
              class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
            >
              <.link
                navigate={~p"/#{@subject.account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                SJC VPC-1
              </.link>
            </th>
            <td class="px-6 py-4">
              172.16.45.0/24
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
          Delete Gateway
        </.delete_button>
      </:actions>
    </.section_header>
    """
  end
end
