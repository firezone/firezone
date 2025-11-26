defmodule Web.HomeHTML do
  use Web, :html

  def home(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.hero_logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h2
              :if={@accounts != []}
              class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900"
            >
              Sign in with a recently used account
            </h2>

            <div :if={@accounts != []} class="space-y-3 items-center">
              <.account_button
                :for={account <- @accounts}
                account={account}
                params={@params}
              />
            </div>

            <.separator :if={@accounts != []} />

            <.flash kind={:error} flash={@flash} />

            <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
              Sign in using your account ID or slug
            </h2>
            <.form :let={f} for={%{}} action={~p"/?#{@params}"} class="space-y-4 lg:space-y-6">
              <.input
                field={f[:account_id_or_slug]}
                type="text"
                label="Account ID or Slug"
                prefix={url(~p"/")}
                placeholder="Enter account ID from the welcome email"
                required
                autofocus
              />

              <.button class="w-full" style="info">
                Go to Sign In page
              </.button>
            </.form>

            <p :if={@params["as"] != "client"} class="py-2 text-center">
              Don't have an account?
              <a href={~p"/sign_up"} class={[link_style()]}>
                Sign up here.
              </a>
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def account_button(assigns) do
    ~H"""
    <a href={~p"/#{@account}?#{@params}"} class={~w[
          w-full inline-flex items-center justify-center py-2.5 px-5
          bg-white rounded
          text-sm text-neutral-900
          border border-neutral-200
          hover:bg-neutral-100 hover:text-neutral-900
    ]}>
      {@account.name}
    </a>
    """
  end

  def separator(assigns) do
    ~H"""
    <div class="flex items-center">
      <div class="w-full h-0.5 bg-neutral-200"></div>
      <div class="px-5 text-center text-neutral-500">or</div>
      <div class="w-full h-0.5 bg-neutral-200"></div>
    </div>
    """
  end
end
