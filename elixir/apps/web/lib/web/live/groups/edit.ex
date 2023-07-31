defmodule Web.GroupsLive.Edit do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}>
        Engineering
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/DF43E951-7DFB-4921-8F7F-BF0F8D31FA89/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing group <code>Engineering</code>
      </:title>
    </.header>
    <!-- Update Group -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit group details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="first-name">
                Name
              </.label>
              <input
                type="text"
                name="name"
                id="name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                value="Engineering"
                required=""
              />
            </div>
            <div>
              <.label for="group-users">
                Users
              </.label>
              <select
                multiple
                aria-described-by="groups-explanation"
                id="group-users"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500"
              >
                <option selected value="F8062FF0-ED0C-4B6C-9FA2-F6090E389423">
                  Bou Kheir, Jamil
                </option>
                <option selected value="E8062FF0-ED0C-4B6C-9FA2-F6090E389423">Johnson, Steve</option>
                <option value="B8062FF0-ED0C-4B6C-9FA2-F6090E389423">Steinberg, Gabriel</option>
              </select>
              <p id="groups-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select or deselect users to add to this group. Only manually-added users are shown.
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
