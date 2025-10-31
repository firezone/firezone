defmodule Web.SignIn do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  alias Domain.{
    Auth,
    Accounts,
    Repo,
    Google,
    EmailOTP,
    Entra,
    Okta,
    OIDC,
    Userpass
  }

  @root_adapters_whitelist [:email, :userpass, :openid_connect]

  def mount(%{"account_id_or_slug" => account_id_or_slug} = params, _session, socket) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug) do
      if Domain.Migrator.migrated?(account) do
        mount_migrated_account(account, params, socket)
      else
        mount_legacy_account(account, params, socket)
      end
    else
      _other ->
        raise Web.LiveErrors.NotFoundError, skip_sentry: true
    end
  end

  defp mount_migrated_account(account, params, socket) do
    socket =
      assign(socket,
        migrated?: true,
        page_title: "Sign In",
        account: account,
        params: Web.Auth.take_sign_in_params(params),
        google_auth_providers: auth_providers(account, Google.AuthProvider),
        okta_auth_providers: auth_providers(account, Okta.AuthProvider),
        entra_auth_providers: auth_providers(account, Entra.AuthProvider),
        oidc_auth_providers: auth_providers(account, OIDC.AuthProvider),
        email_otp_auth_provider: auth_providers(account, EmailOTP.AuthProvider),
        userpass_auth_provider: auth_providers(account, Userpass.AuthProvider)
      )

    {:ok, socket}
  end

  def mount_legacy_account(account, params, socket) do
    with [_ | _] = providers <- Auth.all_active_providers_for_account!(account) do
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
        raise Web.LiveErrors.NotFoundError, skip_sentry: true
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

  def render(%{migrated?: true} = assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.hero_logo text={@account.name} />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />

            <.flash :if={not Accounts.account_active?(@account)} kind={:error} style="wide">
              This account has been disabled. Please contact your administrator to re-enable it.
            </.flash>

            <%= if trial_ends_at = get_in(@account.metadata.stripe.trial_ends_at) do %>
              <% trial_ends_in_days = trial_ends_at |> DateTime.diff(DateTime.utc_now(), :day) %>

              <.flash :if={trial_ends_in_days <= 0} kind={:error}>
                Your trial has expired and needs to be renewed.
                Contact your account manager or administrator to ensure uninterrupted service.
              </.flash>
            <% end %>

            <.intersperse_blocks :if={not disabled?(@account, @params)}>
              <:separator>
                <.separator />
              </:separator>

              <:item :if={
                Enum.any?(
                  @google_auth_providers ++
                    @okta_auth_providers ++ @entra_auth_providers ++ @oidc_auth_providers
                )
              }>
                <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
                  Sign in with a configured provider
                </h2>

                <div class="space-y-3 items-center">
                  <.auth_button
                    :for={provider <- @google_auth_providers}
                    account={@account}
                    params={@params}
                    provider={provider}
                    type="google"
                  >
                    <:icon>
                      <img
                        src={~p"/images/google-logo.svg"}
                        alt="Google Workspace Logo"
                        class="w-5 h-5 mr-2"
                      />
                    </:icon>
                  </.auth_button>

                  <.auth_button
                    :for={provider <- @okta_auth_providers}
                    account={@account}
                    params={@params}
                    provider={provider}
                    type="okta"
                  >
                    <:icon>
                      <img src={~p"/images/okta-logo.svg"} alt="Okta Logo" class="w-5 h-5 mr-2" />
                    </:icon>
                  </.auth_button>

                  <.auth_button
                    :for={provider <- @entra_auth_providers}
                    account={@account}
                    params={@params}
                    provider={provider}
                    type="entra"
                  >
                    <:icon>
                      <img
                        src={~p"/images/entra-logo.svg"}
                        alt="Microsoft Entra Logo"
                        class="w-5 h-5 mr-2"
                      />
                    </:icon>
                  </.auth_button>

                  <.auth_button
                    :for={provider <- @oidc_auth_providers}
                    account={@account}
                    params={@params}
                    provider={provider}
                    type="oidc"
                  >
                    <:icon>
                      <img
                        src={~p"/images/openid-logo.svg"}
                        alt="OpenID Connect Logo"
                        class="w-5 h-5 mr-2"
                      />
                    </:icon>
                  </.auth_button>
                </div>
              </:item>

              <:item :if={@email_otp_auth_provider}>
                <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
                  Sign in with email
                </h2>

                <.migrated_email_form
                  provider={@email_otp_auth_provider}
                  account={@account}
                  flash={@flash}
                  params={@params}
                />
              </:item>

              <:item :if={@userpass_auth_provider}>
                <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
                  Sign in with username and password
                </h2>

                <.migrated_userpass_form
                  provider={@userpass_auth_provider}
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
            <.website_link path="/kb/client-apps">Read the docs.</.website_link>
          </p>
          <p class="py-2">
            Looking for a different account?
            <.link href={~p"/"} class={[link_style()]}>
              See recently used accounts.
            </.link>
          </p>
        </div>
      </div>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.hero_logo text={@account.name} />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />

            <.flash :if={not Accounts.account_active?(@account)} kind={:error} style="wide">
              This account has been disabled. Please contact your administrator to re-enable it.
            </.flash>

            <%= if trial_ends_at = get_in(@account.metadata.stripe.trial_ends_at) do %>
              <% trial_ends_in_days = trial_ends_at |> DateTime.diff(DateTime.utc_now(), :day) %>

              <.flash :if={trial_ends_in_days <= 0} kind={:error}>
                Your Enterprise pilot needs to be renewed.
                Contact your system administrator to ensure uninterrupted service.
              </.flash>
            <% end %>

            <.intersperse_blocks :if={not disabled?(@account, @params)}>
              <:separator>
                <.separator />
              </:separator>

              <:item :if={adapter_enabled?(@providers_by_adapter, :openid_connect)}>
                <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
                  Sign in with a configured provider
                </h2>

                <.providers_group_form
                  adapter="openid_connect"
                  providers={@providers_by_adapter[:openid_connect]}
                  account={@account}
                  params={@params}
                />
              </:item>

              <:item :if={adapter_enabled?(@providers_by_adapter, :userpass)}>
                <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
                  Sign in with username and password
                </h2>

                <.providers_group_form
                  adapter="userpass"
                  provider={List.first(@providers_by_adapter[:userpass])}
                  account={@account}
                  flash={@flash}
                  params={@params}
                />
              </:item>

              <:item :if={adapter_enabled?(@providers_by_adapter, :email)}>
                <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
                  Sign in with email
                </h2>

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
            <.website_link path="/kb/client-apps">Read the docs.</.website_link>
          </p>
          <p class="py-2">
            Looking for a different account?
            <.link href={~p"/"} class={[link_style()]}>
              See recently used accounts.
            </.link>
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
    provider_identifier = Phoenix.Flash.get(assigns.flash, :userpass_provider_identifier)
    form = to_form(%{"provider_identifier" => provider_identifier}, as: "userpass")
    assigns = Map.put(assigns, :userpass_form, form)

    ~H"""
    <.form
      for={@userpass_form}
      action={~p"/#{@account}/sign_in/providers/#{@provider.id}/verify_credentials"}
      class="space-y-4 lg:space-y-6"
      id="userpass_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#userpass_form")}
    >
      <div class="bg-white grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
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
          placeholder="Enter your password"
          required
        />
      </div>

      <.submit_button class="w-full" style="info" icon="hero-key">
        Sign in
      </.submit_button>
    </.form>
    """
  end

  def providers_group_form(%{adapter: "email"} = assigns) do
    provider_identifier = Phoenix.Flash.get(assigns.flash, :email_provider_identifier)
    form = to_form(%{"provider_identifier" => provider_identifier}, as: "email")
    assigns = Map.put(assigns, :email_form, form)

    ~H"""
    <.form
      for={@email_form}
      action={~p"/#{@account}/sign_in/providers/#{@provider.id}/request_email_otp"}
      class="space-y-4 lg:space-y-6"
      id="email_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#email_form")}
    >
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />

      <.input
        field={@email_form[:provider_identifier]}
        type="email"
        label="Email"
        placeholder="Enter your email"
        required
      />
      <.submit_button class="w-full" style="info" icon="hero-envelope">
        Request sign in token
      </.submit_button>
    </.form>
    """
  end

  def openid_connect_button(assigns) do
    ~H"""
    <a
      class={[button_style("info"), button_size("md"), "w-full space-x-1"]}
      href={~p"/#{@account}/sign_in/providers/#{@provider}/redirect?#{@params}"}
    >
      <.provider_icon adapter={@provider.adapter} class="w-5 h-5 mr-2" /> Sign in with
      <strong>{@provider.name}</strong>
    </a>
    """
  end

  attr :type, :string, required: true
  attr :provider, :any, required: true
  attr :account, :any, required: true
  attr :params, :map, required: true
  slot :icon

  defp auth_button(assigns) do
    ~H"""
    <.link
      class={[button_style("info"), button_size("md"), "w-full space-x-1"]}
      href={~p"/#{@account}/sign_in/#{@type}/#{@provider.id}?#{@params}"}
    >
      {render_slot(@icon)} Sign in with <strong>{@provider.name}</strong>
    </.link>
    """
  end

  # Migrated account forms
  def migrated_userpass_form(assigns) do
    idp_id = Phoenix.Flash.get(assigns.flash, :userpass_idp_id)
    form = to_form(%{"idp_id" => idp_id}, as: "userpass")
    assigns = Map.put(assigns, :userpass_form, form)

    ~H"""
    <.form
      for={@userpass_form}
      action={~p"/#{@account}/sign_in/userpass/#{@provider.id}"}
      class="space-y-4 lg:space-y-6"
      id="userpass_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#userpass_form")}
    >
      <div class="bg-white grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
        <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />

        <.input
          field={@userpass_form[:idp_id]}
          type="text"
          label="Username"
          placeholder="Enter your username"
          required
        />

        <.input
          field={@userpass_form[:secret]}
          type="password"
          label="Password"
          placeholder="Enter your password"
          required
        />
      </div>

      <.submit_button class="w-full" style="info" icon="hero-key">
        Sign in
      </.submit_button>
    </.form>
    """
  end

  def migrated_email_form(assigns) do
    idp_id = Phoenix.Flash.get(assigns.flash, :email_idp_id)
    form = to_form(%{"idp_id" => idp_id}, as: "email")
    assigns = Map.put(assigns, :email_form, form)

    ~H"""
    <.form
      for={@email_form}
      action={~p"/#{@account}/sign_in/email_otp/#{@provider.id}"}
      class="space-y-4 lg:space-y-6"
      id="email_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#email_form")}
    >
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />

      <.input
        field={@email_form[:idp_id]}
        type="email"
        label="Email"
        placeholder="Enter your email"
        required
      />
      <.submit_button class="w-full" style="info" icon="hero-envelope">
        Request sign in token
      </.submit_button>
    </.form>
    """
  end

  def adapter_enabled?(providers_by_adapter, adapter) do
    Map.get(providers_by_adapter, adapter, []) != []
  end

  defp auth_providers(account, module) do
    import Ecto.Query

    queryable = from(ap in module, where: ap.account_id == ^account.id and not ap.is_disabled)

    if module in [EmailOTP.AuthProvider, Userpass.AuthProvider] do
      Repo.one(queryable)
    else
      Repo.all(queryable)
    end
  end
end
