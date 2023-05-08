defmodule Web.UsersLive.New do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <!-- Breadcrumbs -->
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/"},
          %{label: "Users", path: ~p"/users"},
          %{label: "Add user", path: ~p"/users/new"}
        ]} />
        <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
          Add a new user
        </h1>
      </div>
    </div>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">User details</h2>
        <form action="#">
          <div class="grid gap-4 sm:grid-cols-1 sm:gap-6">
            <div>
              <label
                for="first-name"
                class="block mb-2 text-sm font-medium text-gray-900 dark:text-white"
              >
                First name
              </label>
              <input
                type="text"
                name="first-name"
                id="first-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
              />
            </div>
            <div>
              <label
                for="last-name"
                class="block mb-2 text-sm font-medium text-gray-900 dark:text-white"
              >
                Last name
              </label>
              <input
                type="text"
                name="last-name"
                id="last-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
              />
            </div>
            <div>
              <label for="email" class="block mb-2 text-sm font-medium text-gray-900 dark:text-white">
                Email
              </label>
              <input
                aria-described-by="email-explanation"
                type="email"
                name="email"
                id="email"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
              />
              <p id="email-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                We'll send a confirmation email to this address.
              </p>
            </div>
            <div>
              <label
                for="confirm-email"
                class="block mb-2 text-sm font-medium text-gray-900 dark:text-white"
              >
                Confirm email
              </label>
              <input
                type="email"
                name="confirm-email"
                id="confirm-email"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
              />
            </div>
            <div>
              <label
                for="user-role"
                class="block mb-2 text-sm font-medium text-gray-900 dark:text-white"
              >
                Role
              </label>
              <select
                aria-described-by="role-explanation"
                id="user-role"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500"
              >
                <option value="end-user">End user</option>
                <option value="admin">Admin</option>
              </select>
              <p id="role-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select Admin to make this user an administrator of your organization.
              </p>
            </div>
            <div>
              <label
                for="user-groups"
                class="block mb-2 text-sm font-medium text-gray-900 dark:text-white"
              >
                Groups
              </label>
              <select
                multiple
                aria-described-by="groups-explanation"
                id="user-groups"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500"
              >
                <option value="engineering">Engineering</option>
                <option value="devops">DevOps</option>
              </select>
              <p id="groups-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select one or more groups to allow this user access to resources.
              </p>
            </div>
          </div>
          <button
            type="submit"
            class="inline-flex items-center px-5 py-2.5 mt-4 sm:mt-6 text-sm font-medium text-center text-white bg-primary-700 rounded-lg focus:ring-4 focus:ring-primary-200 dark:focus:ring-primary-900 hover:bg-primary-800"
          >
            Add user
          </button>
        </form>
      </div>
    </section>
    """
  end
end
