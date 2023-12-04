defmodule Web.HomeHTML do
  use Web, :html

  def home(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl text-center leading-tight tracking-tight text-neutral-900 sm:text-2xl">
              Welcome to Firezone
            </h1>

            <h3
              :if={@accounts != []}
              class="text-m leading-tight tracking-tight text-neutral-900 sm:text-xl"
            >
              Recently used accounts
            </h3>

            <div :if={@accounts != []} class="space-y-3 items-center">
              <.account_button
                :for={account <- @accounts}
                account={account}
                signed_in?={account.id in @signed_in_account_ids}
                redirect_params={@redirect_params}
              />
            </div>

            <.separator :if={@accounts != []} />

            <.form
              :let={f}
              for={%{}}
              action={~p"/?#{@redirect_params}"}
              class="space-y-4 lg:space-y-6"
            >
              <.input
                field={f[:account_id_or_slug]}
                type="text"
                label="Account ID or Slug"
                prefix={url(~p"/")}
                required
                autofocus
              />
              <p>As shown in your "Welcome to Firezone" email</p>

              <.button class="w-full">
                Go to Sign In page
              </.button>
            </.form>
            <p
              :if={Domain.Config.sign_up_enabled?() and is_nil(@redirect_params["client_platform"])}
              class="py-2"
            >
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
    <a href={~p"/#{@account}?#{@redirect_params}"} class={~w[
          w-full inline-flex items-center justify-center py-2.5 px-5
          bg-white rounded
          text-sm text-neutral-900
          border border-neutral-200
          hover:bg-neutral-100 hover:text-neutral-900
    ]}>
      <%= @account.name %>

      <span :if={@signed_in?} class="text-green-400 pl-1">
        <.icon name="hero-shield-check" class="w-4 h-4" />
      </span>
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
