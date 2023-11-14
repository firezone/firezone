defmodule Web.HomeHTML do
  use Web, :html

  def home(assigns) do
    ~H"""
    <section class="bg-gray-50 dark:bg-gray-900">
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow dark:bg-gray-800 md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl text-center font-bold leading-tight tracking-tight text-gray-900 sm:text-2xl dark:text-white">
              Welcome to Firezone
            </h1>

            <h3
              :if={@accounts != []}
              class="text-m font-bold leading-tight tracking-tight text-gray-900 sm:text-xl dark:text-white"
            >
              Recently used accounts
            </h3>

            <div :if={@accounts != []} class="space-y-3 items-center">
              <.account_button :for={account <- @accounts} account={account} />
            </div>

            <.separator if={@accounts != []} />

            <.form :let={f} for={%{}} action={~p"/"} class="space-y-4 lg:space-y-6">
              <.input
                field={f[:account_id_or_slug]}
                type="text"
                label="Account ID or Slug"
                placeholder={~s|As shown in your "Welcome to Firezone" email|}
                required
              />

              <.button class="w-full">
                Go to Sign In page
              </.button>
            </.form>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def account_button(assigns) do
    ~H"""
    <a href={~p"/#{@account}"} class={~w[
          w-full inline-flex items-center justify-center py-2.5 px-5
          bg-white rounded
          text-sm font-medium text-gray-900
          focus:outline-none
          border border-gray-200
          hover:bg-gray-100 hover:text-gray-900
          focus:z-10 focus:ring-4 focus:ring-gray-200
          dark:focus:ring-gray-700 dark:bg-gray-800 dark:text-gray-400
          dark:border-gray-600 dark:hover:text-white dark:hover:bg-gray-700]}>
      <%= @account.name %>
    </a>
    """
  end

  def separator(assigns) do
    ~H"""
    <div class="flex items-center">
      <div class="w-full h-0.5 bg-gray-200 dark:bg-gray-700"></div>
      <div class="px-5 text-center text-gray-500 dark:text-gray-400">or</div>
      <div class="w-full h-0.5 bg-gray-200 dark:bg-gray-700"></div>
    </div>
    """
  end
end
