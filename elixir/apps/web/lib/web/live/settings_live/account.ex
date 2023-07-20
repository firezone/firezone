defmodule Web.SettingsLive.Account do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/settings/account"}>Account Settings</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        User profile
      </:title>
    </.header>
    <!-- Account details -->
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
              Jamil
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
              Bou Kheir
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Authentication method
            </th>
            <td class="px-6 py-4">
              Magic link
              <p class="text-xs">
                <.link class="text-xs text-blue-600 dark:text-blue-500 hover:underline" href="#">
                  <!-- TODO: Open modal with list of IdPs to allow administrator to choose which one to use for sign in, warning him/her that this is irreversible. -->
                  Migrate your account
                </.link>
                to authenticate with a connected Identity Provider instead.
              </p>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Sign in email
            </th>
            <td class="px-6 py-4">
              jamil@firezone.dev
              <p class="text-xs">
                <a
                  class="text-blue-600 dark:text-gray-500 hover:underline"
                  href="mailto:support@firezone.dev"
                >
                  Contact support
                </a>
                to change your sign-in email.
              </p>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <!-- License details -->
    <.header>
      <:title>
        License
      </:title>
    </.header>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.icon name="hero-exclamation-triangle" class="inline-block w-5 h-5 mr-1 text-yellow-500" />
      You have <strong>17 days</strong>
      remaining in your trial, after which you'll be downgraded to the <strong>Free</strong>
      plan.
      <.link class="text-blue-600 dark:text-blue-500 hover:underline" href="#">
        Add a credit card
      </.link>
      to avoid service interruption.
    </p>
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <tbody>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Plan
            </th>
            <td class="px-6 py-4">
              Team
              <p>
                <.link class="text-xs text-blue-600 dark:text-blue-500 hover:underline" href="#">
                  Change plan
                </.link>
              </p>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Seats
            </th>
            <td class="px-6 py-4">
              5
              <p>
                <.link class="text-xs text-blue-600 dark:text-blue-500 hover:underline" href="#">
                  Add or remove seats
                </.link>
              </p>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Renews on
            </th>
            <td class="px-6 py-4">
              October 1, 2021
              <p>
                <.link class="text-xs text-blue-600 dark:text-blue-500 hover:underline" href="#">
                  Cancel renewal
                </.link>
              </p>
            </td>
          </tr>
          <tr class="border-b border-gray-200 dark:border-gray-700">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-gray-900 whitespace-nowrap bg-gray-50 dark:text-white dark:bg-gray-800"
            >
              Billed amount
            </th>
            <td class="px-6 py-4">
              <strong>$500/year</strong>
              for <strong>5 seats</strong>
              <span class="bg-green-100 text-green-800 text-xs font-medium mr-2 px-2.5 py-0.5 rounded dark:bg-green-900 dark:text-green-300">
                10% discount applied
              </span>
              <p>
                <.link class="text-xs text-blue-600 dark:text-blue-500 hover:underline" href="#">
                  Switch to monthly billing
                </.link>
              </p>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <!-- Danger zone -->
    <.header>
      <:title>
        Danger zone
      </:title>
    </.header>
    <h3 class="ml-4 mb-4 font-bold text-gray-900 dark:text-white">
      Terminate account
    </h3>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.icon name="hero-exclamation-circle" class="inline-block w-5 h-5 mr-1 text-red-500" />
      To disable your account and schedule it for deletion, please <.link
        class="text-blue-600 dark:text-blue-500 hover:underline"
        href="mailto:support@firezone.dev"
      >
        contact support
      </.link>.
    </p>
    """
  end
end
