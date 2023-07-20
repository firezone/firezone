defmodule Web.SettingsLive.Dns do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/settings/dns"}>DNS Settings</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        DNS
      </:title>
    </.header>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      Configure the default resolver used by connected Devices in your Firezone network. Queries for
      defined Resources will <strong>always</strong>
      use Firezone's internal DNS. All other queries will
      use the resolver configured below.
    </p>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.link
        class="text-blue-600 dark:text-blue-500 hover:underline"
        href="https://www.firezone.dev/docs/architecture/dns"
        target="_blank"
      >
        Read more about how DNS works in Firezone.
        <.icon name="hero-arrow-top-right-on-square" class="-ml-1 mb-3 w-3 h-3" />
      </.link>
    </p>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Device DNS</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <label
                for="resolver"
                class="block mb-2 text-sm font-medium text-gray-900 dark:text-white"
              >
                Resolver
              </label>
              <select
                id="resolver"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500"
              >
                <option>System default</option>
                <option selected>Custom</option>
              </select>
            </div>
            <div>
              <.label for="resolver-address">
                Address
              </.label>
              <input
                type="text"
                name="address"
                id="resolver-address"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="https://doh.familyshield.opendns.com/dns-query"
                required
              />
              <p id="address-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                IP addresses, FQDNs, and DNS-over-HTTPS (DoH) addresses are supported.
              </p>
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
