defmodule Web.ResourcesLive.Edit do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Resources", path: ~p"/#{@subject.account}/resources"},
          %{
            label: "GitLab",
            path: ~p"/#{@subject.account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
          },
          %{
            label: "Edit",
            path: ~p"/#{@subject.account}/resources/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Edit Resource
      </:title>
    </.section_header>
    <!-- Edit Resource -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit Resource details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="address">
                Address
              </.label>
              <input
                autocomplete="off"
                type="text"
                name="address"
                id="resource-address"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="www.gitlab.com"
                required
              />
            </div>
            <div>
              <.label for="name">
                Name
              </.label>
              <input
                type="text"
                name="name"
                id="resource-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="GitLab"
                required
              />
            </div>
            <div class="w-full">
              <.label for="traffic-filter">
                Traffic restriction
              </.label>
              <div class="h-12 flex items-center my-4">
                <input
                  id="traffic-filter-option-1"
                  type="radio"
                  name="traffic-filter"
                  value="none"
                  class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:focus:bg-blue-600 dark:bg-gray-700 dark:border-gray-600"
                />
                <label
                  for="traffic-filter-option-1"
                  class="block ml-4 text-sm font-medium text-gray-900 dark:text-gray-300"
                >
                  Permit all
                </label>
              </div>
              <div class="h-12 flex items-center mb-4">
                <input
                  id="traffic-filter-option-2"
                  type="radio"
                  name="traffic-filter"
                  value="icmp"
                  class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:focus:bg-blue-600 dark:bg-gray-700 dark:border-gray-600"
                />
                <label
                  for="traffic-filter-option-2"
                  class="block ml-4 text-sm font-medium text-gray-900 dark:text-gray-300"
                >
                  ICMP
                </label>
              </div>
              <div class="h-12 flex items-center mb-4">
                <input
                  id="traffic-filter-option-3"
                  type="radio"
                  name="traffic-filter"
                  value="tcp"
                  class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:focus:bg-blue-600 dark:bg-gray-700 dark:border-gray-600"
                />
                <label
                  for="traffic-filter-option-3"
                  class="block ml-4 text-sm font-medium text-gray-900 dark:text-gray-300"
                >
                  TCP
                </label>
                <input
                  disabled
                  placeholder="Enter port range(s)"
                  id="tcp-port"
                  name="tcp-port"
                  class="ml-8 bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-48 p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                />
              </div>
              <div class="h-12 flex items-center">
                <input
                  id="traffic-filter-option-4"
                  type="radio"
                  name="traffic-filter"
                  value="udp"
                  class="w-4 h-4 border-gray-300 focus:ring-2 focus:ring-blue-300 dark:focus:ring-blue-600 dark:focus:bg-blue-600 dark:bg-gray-700 dark:border-gray-600"
                  checked
                />
                <label
                  for="traffic-filter-option-4"
                  class="block ml-4 text-sm font-medium text-gray-900 dark:text-gray-300"
                >
                  UDP
                </label>
                <input
                  value="53"
                  placeholder="Enter port range(s)"
                  id="udp-port"
                  name="udp-port"
                  class="ml-8 bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-48 p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                />
              </div>
            </div>
            <div>
              <.label for="gateways">
                Gateway(s)
              </.label>

              <div class="rounded-lg relative overflow-x-auto">
                <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
                  <thead class="text-xs text-gray-700 uppercase bg-gray-50 dark:bg-gray-700 dark:text-gray-400">
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
                      <th scope="col" class="px-6 py-3"></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr class="bg-white border-b dark:bg-gray-800 dark:border-gray-700">
                      <th
                        scope="row"
                        class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
                      >
                        aws-primary
                      </th>
                      <td class="px-6 py-4">
                        <code class="block text-xs">201.45.66.101</code>
                      </td>
                      <td class="px-6 py-4">
                        <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                          Online
                        </span>
                      </td>
                      <td class="px-6 py-4">
                        <a
                          href="#"
                          class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                        >
                          Link
                        </a>
                      </td>
                    </tr>
                    <tr class="bg-white border-b dark:bg-gray-800 dark:border-gray-700">
                      <th
                        scope="row"
                        class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
                      >
                        aws-secondary
                      </th>
                      <td class="px-6 py-4">
                        <code class="block text-xs">11.34.176.175</code>
                      </td>
                      <td class="px-6 py-4">
                        <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                          Online
                        </span>
                      </td>
                      <td class="px-6 py-4">
                        <a
                          href="#"
                          class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                        >
                          Link
                        </a>
                      </td>
                    </tr>
                    <tr class="bg-white border-b dark:bg-gray-800 dark:border-gray-700">
                      <th
                        scope="row"
                        class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
                      >
                        gcp-primary
                      </th>
                      <td class="px-6 py-4">
                        <code class="block text-xs">45.11.23.17</code>
                      </td>
                      <td class="px-6 py-4">
                        <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                          Online
                        </span>
                      </td>
                      <td class="px-6 py-4">
                        <a
                          href="#"
                          class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                        >
                          Link
                        </a>
                      </td>
                    </tr>
                    <tr class="bg-white border-b dark:bg-gray-800 dark:border-gray-700">
                      <th
                        scope="row"
                        class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap dark:text-white"
                      >
                        gcp-secondary
                      </th>
                      <td class="px-6 py-4">
                        <code class="block text-xs">80.113.105.104</code>
                      </td>
                      <td class="px-6 py-4">
                        <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                          Online
                        </span>
                      </td>
                      <td class="px-6 py-4">
                        <a
                          href="#"
                          class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
                        >
                          Link
                        </a>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
          <div class="flex items-center space-x-4">
            <button
              type="submit"
              class="text-white bg-primary-700 hover:bg-primary-800 focus:ring-4 focus:outline-none focus:ring-primary-300 font-medium rounded-lg text-sm px-5 py-2.5 text-center dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800"
            >
              Save
            </button>
          </div>
        </form>
      </div>
    </section>
    """
  end
end
