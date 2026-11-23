defmodule PortalWeb.SignIn do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}

  alias Portal.{
    Safe,
    Google,
    GitHub,
    EmailOTP,
    Entra,
    Okta,
    OIDC,
    Userpass
  }

  alias __MODULE__.Database
  alias PortalWeb.Components.AuthPage

  def mount(%{"account_id_or_slug" => account_id_or_slug} = params, session, socket) do
    account = PortalWeb.Accounts.get_by_id_or_slug!(account_id_or_slug)
    mount_account(account, params, session, socket)
  end

  @doc """
  Used as the session function for the sign in live_session.
  """
  def live_session(conn) do
    conn
    |> PortalWeb.Cookie.LastUsedProvider.fetch_state()
    |> Map.put("oauth_client", oauth_client(conn))
  end

  defp mount_account(account, params, session, socket) do
    connecting_client = with_logo(session["oauth_client"])

    socket =
      assign(socket,
        page_title: "Sign In",
        account: account,
        params: PortalWeb.Authentication.take_sign_in_params(params),
        connecting_client: connecting_client,
        last_used_provider_id: session["last_used_provider_id"],
        google_auth_providers: auth_providers(account, Google.AuthProvider),
        github_auth_providers: auth_providers(account, GitHub.AuthProvider),
        okta_auth_providers: auth_providers(account, Okta.AuthProvider),
        entra_auth_providers: auth_providers(account, Entra.AuthProvider),
        oidc_auth_providers: auth_providers(account, OIDC.AuthProvider),
        email_otp_auth_provider: auth_providers(account, EmailOTP.AuthProvider),
        userpass_auth_provider: auth_providers(account, Userpass.AuthProvider)
      )
      |> hide_last_used_if_only_one_provider()

    if connecting_client do
      # Part of an app connection, so it keeps the centered look the consent
      # screen uses rather than the marketing panel of a plain sign-in.
      {:ok, socket, layout: {PortalWeb.Layouts, :standalone}}
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Core.flash flash={@flash} kind={:error} />
    <Core.flash flash={@flash} kind={:info} />

    <%= if trial_ends_at = get_in(@account.metadata.stripe.trial_ends_at) do %>
      <% trial_ends_in_days = trial_ends_at |> DateTime.diff(DateTime.utc_now(), :day) %>

      <Core.flash :if={trial_ends_in_days <= 0} kind={:error}>
        Your trial has expired and needs to be renewed.
        Contact your account manager or administrator to ensure uninterrupted service.
      </Core.flash>
    <% end %>

    <Page.oauth_client_header :if={@connecting_client} client={@connecting_client} />

    <AuthPage.heading title={"Sign in to #{@account.name}"}>
      Choose how you'd like to sign in.
    </AuthPage.heading>

    <Core.intersperse_blocks>
      <:separator>
        <AuthPage.separator />
      </:separator>

      <:item :if={
        Enum.any?(
          @google_auth_providers ++
            @github_auth_providers ++
            @okta_auth_providers ++ @entra_auth_providers ++ @oidc_auth_providers
        )
      }>
        <div class="flex flex-col gap-2">
          <.auth_button
            :for={provider <- @google_auth_providers}
            account={@account}
            params={@params}
            provider={provider}
            last_used={provider.id == @last_used_provider_id}
            type="google"
          >
            <:icon>
              <Core.provider_icon provider="google" size="md" />
            </:icon>
          </.auth_button>

          <.auth_button
            :for={provider <- @github_auth_providers}
            account={@account}
            params={@params}
            provider={provider}
            last_used={provider.id == @last_used_provider_id}
            type="github"
          >
            <:icon>
              <Core.provider_icon provider="github" size="md" />
            </:icon>
          </.auth_button>

          <.auth_button
            :for={provider <- @okta_auth_providers}
            account={@account}
            params={@params}
            provider={provider}
            last_used={provider.id == @last_used_provider_id}
            type="okta"
          >
            <:icon>
              <Core.provider_icon provider="okta" size="md" />
            </:icon>
          </.auth_button>

          <.auth_button
            :for={provider <- @entra_auth_providers}
            account={@account}
            params={@params}
            provider={provider}
            last_used={provider.id == @last_used_provider_id}
            type="entra"
          >
            <:icon>
              <Core.provider_icon provider="entra" size="md" />
            </:icon>
          </.auth_button>

          <.auth_button
            :for={provider <- @oidc_auth_providers}
            account={@account}
            params={@params}
            provider={provider}
            last_used={provider.id == @last_used_provider_id}
            type="oidc"
          >
            <:icon>
              <Core.provider_icon provider={Core.provider_type_from_issuer(provider.issuer)} size="md" />
            </:icon>
          </.auth_button>
        </div>
      </:item>

      <:item :if={@email_otp_auth_provider}>
        <.email_form
          provider={@email_otp_auth_provider}
          last_used={@email_otp_auth_provider.id == @last_used_provider_id}
          account={@account}
          flash={@flash}
          params={@params}
        />
      </:item>

      <:item :if={@userpass_auth_provider}>
        <.userpass_form
          provider={@userpass_auth_provider}
          last_used={@userpass_auth_provider.id == @last_used_provider_id}
          account={@account}
          flash={@flash}
          params={@params}
        />
      </:item>
    </Core.intersperse_blocks>

    <div
      :if={!PortalWeb.Authentication.client_sign_in?(@params) and is_nil(@connecting_client)}
      id="sign-in-footer"
      class="mt-10 pt-4 space-y-1"
    >
      <p class="text-sm text-muted">
        Meant to sign in from a client instead?
        <Navigation.website_link path="/kb/client-apps" class={AuthPage.link_class()}>
          Read the docs.
        </Navigation.website_link>
      </p>
      <p class="text-sm text-muted mt-1">
        Looking for a different account?
        <Navigation.link href={~p"/sign_in"} class={AuthPage.link_class()}>
          See recently used accounts.
        </Navigation.link>
      </p>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :provider, :any, required: true
  attr :account, :any, required: true
  attr :params, :map, required: true
  attr :last_used, :boolean, default: false
  slot :icon

  defp auth_button(assigns) do
    ~H"""
    <Navigation.link
      class={AuthPage.option_button_class()}
      href={~p"/#{@account}/sign_in/#{@type}/#{@provider.id}?#{@params}"}
    >
      {render_slot(@icon)}
      <span class="flex-1 truncate">Continue with <strong>{@provider.name}</strong></span>
      <Core.badge :if={@last_used} type="primary" class="shrink-0">Last used</Core.badge>
      <Core.icon name="ri-arrow-right-line" class={AuthPage.option_arrow_class()} />
    </Navigation.link>
    """
  end

  def userpass_form(assigns) do
    idp_id = Phoenix.Flash.get(assigns.flash, :userpass_idp_id)
    form = to_form(%{"idp_id" => idp_id}, as: "userpass")
    assigns = Map.put(assigns, :userpass_form, form)

    ~H"""
    <.form
      for={@userpass_form}
      action={~p"/#{@account}/sign_in/userpass/#{@provider.id}"}
      class="flex flex-col gap-3"
      id="userpass_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#userpass_form")}
    >
      <Core.badge :if={assigns[:last_used]} type="primary" class="self-start mb-2 w-fit">
        Last used
      </Core.badge>
      <Form.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
      <label for="userpass_idp_id" class="sr-only">Username</label>
      <input
        type="text"
        id="userpass_idp_id"
        name="userpass[idp_id]"
        value={@userpass_form[:idp_id].value}
        placeholder="Username"
        autocomplete="username"
        class={AuthPage.input_class()}
        required
      />
      <label for="userpass_secret" class="sr-only">Password</label>
      <input
        type="password"
        id="userpass_secret"
        name="userpass[secret]"
        placeholder="Password"
        autocomplete="current-password"
        class={AuthPage.input_class()}
        required
      />
      <button type="submit" class={[AuthPage.primary_button_class(), "w-full"]}>
        Sign in
      </button>
    </.form>
    """
  end

  def email_form(assigns) do
    email = Phoenix.Flash.get(assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "email")
    assigns = Map.put(assigns, :email_form, form)

    ~H"""
    <.form
      for={@email_form}
      action={~p"/#{@account}/sign_in/email_otp/#{@provider.id}"}
      id="email_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#email_form")}
    >
      <Core.badge :if={assigns[:last_used]} type="primary" class="self-start mb-2 w-fit">
        Last used
      </Core.badge>
      <Form.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
      <label for="email_email" class="block mb-1.5 text-xs font-medium text-muted">Email</label>
      <div class="flex gap-2">
        <input
          type="email"
          id="email_email"
          name="email[email]"
          value={@email_form[:email].value}
          placeholder="you@example.com"
          autocomplete="email"
          class={[AuthPage.input_class(), "flex-1 min-w-0"]}
          required
        />
        <button type="submit" class={AuthPage.primary_button_class()}>
          Send code <Core.icon name="ri-arrow-right-line" class="w-4 h-4" />
        </button>
      </div>
    </.form>
    """
  end

  defp auth_providers(account, module) do
    if module in [EmailOTP.AuthProvider, Userpass.AuthProvider] do
      Database.get_auth_provider(account, module)
    else
      Database.list_auth_providers(account, module)
    end
  end

  defp hide_last_used_if_only_one_provider(socket) do
    a = socket.assigns

    provider_count =
      Enum.count(
        a.google_auth_providers ++
          a.github_auth_providers ++
          a.okta_auth_providers ++
          a.entra_auth_providers ++
          a.oidc_auth_providers ++
          Enum.reject([a.email_otp_auth_provider, a.userpass_auth_provider], &is_nil/1)
      )

    if provider_count > 1 do
      socket
    else
      assign(socket, :last_used_provider_id, nil)
    end
  end

  defp with_logo(%Portal.OAuthClient{client_id: client_id} = client) do
    case Database.get_fresh_logo(client_id) do
      %{logo_data: data, logo_content_type: type} ->
        %{client | logo_data: data, logo_content_type: type}

      nil -> client
    end
  end

  defp with_logo(nil), do: nil

  defp oauth_client(conn) do
    with %{"redirect_to" => redirect_to} <- conn.query_params,
         {:ok, client_id} <- redirect_client_id(redirect_to) do
      PortalWeb.Cookie.OAuthClient.fetch(conn, client_id)
    else
      _other -> nil
    end
  end

  defp redirect_client_id(redirect_to) when is_binary(redirect_to) do
    with %URI{path: path, query: query} when is_binary(query) <- URI.parse(redirect_to),
         true <- String.ends_with?(path || "", "/oauth/authorize"),
         %{"client_id" => client_id} when is_binary(client_id) <- URI.decode_query(query) do
      {:ok, client_id}
    else
      _other -> :error
    end
  end

  defp redirect_client_id(_redirect_to), do: :error

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_auth_provider(account, module) do
      from(ap in module, where: ap.account_id == ^account.id and not ap.is_disabled)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_fresh_logo(client_id) do
      now = DateTime.utc_now()

      from(clients in Portal.OAuthClient,
        where: clients.client_id == ^client_id,
        where: clients.metadata_expires_at > ^now,
        where: not is_nil(clients.logo_data) and not is_nil(clients.logo_content_type),
        select: map(clients, [:logo_data, :logo_content_type])
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def list_auth_providers(account, module) do
      from(ap in module, where: ap.account_id == ^account.id and not ap.is_disabled)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
