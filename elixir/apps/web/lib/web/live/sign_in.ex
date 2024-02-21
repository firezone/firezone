defmodule Web.SignIn do
  use Web, {:live_view, layout: {Web.Layouts, :public}}
  alias Domain.{Auth, Accounts}

  @root_adapters_whitelist [:email, :userpass, :openid_connect]

  def mount(%{"account_id_or_slug" => account_id_or_slug} = params, _session, socket) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, [_ | _] = providers} <- Auth.list_active_providers_for_account(account) do
      providers_by_adapter =
        providers
        |> group_providers_by_root_adapter()
        |> Map.take(@root_adapters_whitelist)

      params = Web.Auth.take_sign_in_params(params)

      socket =
        assign(socket,
          params: params,
          account: account,
          providers_by_adapter: providers_by_adapter,
          page_title: "Sign In"
        )

      {:ok, socket}
    else
      _other ->
        raise Web.LiveErrors.NotFoundError
    end
  end

  defp group_providers_by_root_adapter(providers) do
    providers
    |> Enum.group_by(fn provider ->
      parent_adapter =
        provider
        |> Auth.fetch_provider_capabilities!()
        |> Keyword.get(:parent_adapter)

      parent_adapter || provider.adapter
    end)
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl text-center leading-tight tracking-tight text-neutral-900 sm:text-2xl">
              <span>
                Sign in to <%= @account.name %>
              </span>
            </h1>

            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />

            <.flash :if={not Accounts.account_active?(@account)} kind={:error} style="wide">
              This account has been disabled, please contact your administrator.
            </.flash>

            <.intersperse_blocks :if={not disabled?(@account, @params)}>
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
                <h3 class="text-m leading-tight tracking-tight text-neutral-900 sm:text-xl">
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
                <h3 class="text-m leading-tight tracking-tight text-neutral-900 sm:text-xl">
                  Sign in with email
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
        <div :if={Web.Auth.fetch_auth_context_type!(@params) == :browser} class="mx-auto p-6 sm:p-8">
          <p class="py-2">
            Meant to sign in from a client instead?
            <a href="https://firezone.dev/kb/user-guides?utm_source=product" class={link_style()}>
              Read the docs.
            </a>
          </p>
        </div>
      </div>
    </section>
    """
  end

  def disabled?(account, params) do
    # We allow to sign in to Web UI even for disabled accounts
    case Web.Auth.fetch_auth_context_type!(params) do
      :client -> not Accounts.account_active?(account)
      :browser -> false
    end
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
      <.button phx-disable-with="Sending..." class="w-full" style="info">
        Request sign in token
      </.button>
    </.simple_form>
    """
  end

  def openid_connect_button(assigns) do
    ~H"""
    <.button
      navigate={~p"/#{@account}/sign_in/providers/#{@provider}/redirect?#{@params}"}
      class="w-full space-x-1"
      style="info"
    >
      <.provider_icon adapter={@provider.adapter} class="w-5 h-5 mr-2" /> Sign in with
      <strong><%= @provider.name %></strong>
    </.button>
    """
  end

  def adapter_enabled?(providers_by_adapter, adapter) do
    Map.get(providers_by_adapter, adapter, []) != []
  end
end
