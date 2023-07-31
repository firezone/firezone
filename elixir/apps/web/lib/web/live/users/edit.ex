defmodule Web.UsersLive.Edit do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Users</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
        Jamil Bou Kheir
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing user <code>Bou Kheir, Jamil</code>
      </:title>
    </.header>
    <!-- Update User -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit user details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="first-name">
                First Name
              </.label>
              <input
                type="text"
                name="first-name"
                id="first-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="Steve"
                required=""
              />
            </div>
            <div class="w-full">
              <.label for="last-name">
                Last Name
              </.label>
              <input
                type="text"
                name="last-name"
                id="last-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="Johnson"
                required=""
              />
            </div>
            <div>
              <.label for="email">
                Email
              </.label>
              <input
                aria-describedby="email-explanation"
                type="email"
                name="email"
                id="email"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="steve@tesla.com"
              />
              <p id="email-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                We'll send a confirmation email to both the current email address and the updated one to confirm the change.
              </p>
            </div>
            <div>
              <.label for="confirm-email">
                Confirm email
              </.label>
              <input
                type="email"
                name="confirm-email"
                id="confirm-email"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="steve@tesla.com"
              />
            </div>
            <div>
              <.label for="user-role">
                Role
              </.label>
              <select
                aria-described-by="role-explanation"
                id="user-role"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500"
              >
                <option value="end-user">End user</option>
                <option selected value="admin">Admin</option>
              </select>
              <p id="role-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select Admin to make this user an administrator of your organization.
              </p>
            </div>
            <div>
              <.label for="user-groups">
                Groups
              </.label>
              <select
                multiple
                aria-described-by="groups-explanation"
                id="user-groups"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500"
              >
                <option selected value="engineering">Engineering</option>
                <option value="devops">DevOps</option>
                <option selected value="devsecops">DevSecOps</option>
              </select>
              <p id="groups-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select one or more groups to allow this user access to resources.
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
