defmodule Web.Auth.SignIn do
  use Web, {:live_view, layout: {Web.Layouts, :public}}
  alias Domain.{Auth, Accounts}

  def mount(%{"account_id_or_slug" => account_id_or_slug} = params, _session, socket) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, [_ | _] = providers} <- Auth.list_active_providers_for_account(account) do
      providers_by_adapter =
        providers
        |> Enum.group_by(fn provider ->
          parent_adapter =
            provider
            |> Auth.fetch_provider_capabilities!()
            |> Keyword.get(:parent_adapter)

          parent_adapter || provider.adapter
        end)
        |> Map.drop([:token])

      {:ok, socket,
       temporary_assigns: [
         params: Map.take(params, ["client_platform", "client_csrf_token"]),
         account: account,
         providers_by_adapter: providers_by_adapter,
         page_title: "Sign in"
       ]}
    else
      _other ->
        raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <section class="bg-gray-50 dark:bg-gray-900">
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded-lg shadow dark:bg-gray-800 md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl font-bold leading-tight tracking-tight text-gray-900 sm:text-2xl dark:text-white">
              Welcome back
            </h1>

            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />

            <.intersperse_blocks>
              <:separator>
                <.separator />
              </:separator>

              <:item :if={adapter_enabled?(@providers_by_adapter, :openid_connect)}>
                <.providers_group_form
                  adapter="openid_connect"
                  providers={@providers_by_adapter[:openid_connect]}
                  account={@account}
                  params={@params}
                />
              </:item>

              <:item :if={adapter_enabled?(@providers_by_adapter, :userpass)}>
                <h3 class="text-m font-bold leading-tight tracking-tight text-gray-900 sm:text-xl dark:text-white">
                  Sign in with username and password
                </h3>

                <.providers_group_form
                  adapter="userpass"
                  provider={List.first(@providers_by_adapter[:userpass])}
                  account={@account}
                  flash={@flash}
                  params={@params}
                />
              </:item>

              <:item :if={adapter_enabled?(@providers_by_adapter, :email)}>
                <h3 class="text-m font-bold leading-tight tracking-tight text-gray-900 sm:text-xl dark:text-white">
                  Sign in with a magic link
                </h3>

                <.providers_group_form
                  adapter="email"
                  provider={List.first(@providers_by_adapter[:email])}
                  account={@account}
                  flash={@flash}
                  params={@params}
                />
              </:item>
            </.intersperse_blocks>
          </div>
        </div>
      </div>
    </section>
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

  def providers_group_form(%{adapter: "openid_connect"} = assigns) do
    ~H"""
    <div class="space-y-3 items-center">
      <.openid_connect_button
        :for={provider <- @providers}
        provider={provider}
        account={@account}
        params={@params}
      />
    </div>
    """
  end

  def providers_group_form(%{adapter: "userpass"} = assigns) do
    provider_identifier = live_flash(assigns.flash, :userpass_provider_identifier)
    form = to_form(%{"provider_identifier" => provider_identifier}, as: "userpass")
    assigns = Map.put(assigns, :userpass_form, form)

    ~H"""
    <.simple_form
      for={@userpass_form}
      action={~p"/#{@account}/sign_in/providers/#{@provider.id}/verify_credentials"}
      class="space-y-4 lg:space-y-6"
      id="userpass_form"
      phx-update="ignore"
    >
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />

      <.input
        field={@userpass_form[:provider_identifier]}
        type="text"
        label="Username"
        placeholder="Enter your username"
        required
      />

      <.input
        field={@userpass_form[:secret]}
        type="password"
        label="Password"
        placeholder="••••••••"
        required
      />

      <:actions>
        <.button phx-disable-with="Signing in..." class="w-full">
          Sign in
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  def providers_group_form(%{adapter: "email"} = assigns) do
    provider_identifier = live_flash(assigns.flash, :email_provider_identifier)
    form = to_form(%{"provider_identifier" => provider_identifier}, as: "email")
    assigns = Map.put(assigns, :email_form, form)

    ~H"""
    <.simple_form
      for={@email_form}
      action={~p"/#{@account}/sign_in/providers/#{@provider.id}/request_magic_link"}
      class="space-y-4 lg:space-y-6"
      id="email_form"
      phx-update="ignore"
    >
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />

      <.input
        field={@email_form[:provider_identifier]}
        type="email"
        label="Email"
        placeholder="Enter your email"
        required
      />

      <:actions>
        <.button phx-disable-with="Sending..." class="w-full">
          Request sign in link
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  def openid_connect_button(assigns) do
    ~H"""
    <a href={~p"/#{@account}/sign_in/providers/#{@provider}/redirect?#{@params}"} class={~w[
          w-full inline-flex items-center justify-center py-2.5 px-5
          bg-white rounded-lg
          text-sm font-medium text-gray-900
          focus:outline-none
          border border-gray-200
          hover:bg-gray-100 hover:text-gray-900
          focus:z-10 focus:ring-4 focus:ring-gray-200
          dark:focus:ring-gray-700 dark:bg-gray-800 dark:text-gray-400
          dark:border-gray-600 dark:hover:text-white dark:hover:bg-gray-700]}>
      Log in with <%= @provider.name %>
    </a>
    """
  end

  def adapter_enabled?(providers_by_adapter, adapter) do
    Map.get(providers_by_adapter, adapter, []) != []
  end
end
