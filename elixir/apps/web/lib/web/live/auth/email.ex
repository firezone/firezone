defmodule Web.Auth.Email do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  def render(assigns) do
    ~H"""
    <section class="bg-gray-50 dark:bg-gray-900">
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto md:h-screen lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded-lg shadow dark:bg-gray-800 md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl font-bold leading-tight tracking-tight text-gray-900 sm:text-2xl dark:text-white">
              Please check your email
            </h1>
            <p>
              Should the provided email be registered, a sign-in link will be dispatched to your email account.
              Please click this link to proceed with your login.
            </p>
            <p>
              Did not receive it? <a href="?reset">Resend email</a>.
            </p>
            <div class="flex">
              <.dev_email_provider_link url="https://mail.google.com/mail/" name="Gmail" />
              <.email_provider_link url="https://mail.google.com/mail/" name="Gmail" />
              <.email_provider_link url="https://outlook.live.com/mail/" name="Outlook" />
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  if Mix.env() in [:dev, :test] do
    def dev_email_provider_link(assigns) do
      ~H"""
      <.email_provider_link url={~p"/dev/mailbox"} name="Local" />
      """
    end
  else
    def dev_email_provider_link(assigns), do: ~H""
  end

  def email_provider_link(assigns) do
    ~H"""
    <a
      href={@url}
      class="w-1/2 m-2 inline-flex items-center justify-center py-2.5 px-5 text-sm font-medium text-gray-900 focus:outline-none bg-white rounded-lg border border-gray-200 hover:bg-gray-100 hover:text-gray-900 focus:z-10 focus:ring-4 focus:ring-gray-200 dark:focus:ring-gray-700 dark:bg-gray-800 dark:text-gray-400 dark:border-gray-600 dark:hover:text-white dark:hover:bg-gray-700"
    >
      Open <%= @name %>
    </a>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
