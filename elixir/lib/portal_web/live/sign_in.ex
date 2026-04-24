defmodule PortalWeb.SignIn do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}

  alias Portal.{
    Safe,
    Google,
    EmailOTP,
    Entra,
    Okta,
    OIDC,
    Userpass
  }

  alias __MODULE__.Database

  def mount(%{"account_id_or_slug" => account_id_or_slug} = params, _session, socket) do
    account = Database.get_account_by_id_or_slug!(account_id_or_slug)
    mount_account(account, params, socket)
  end

  defp mount_account(account, params, socket) do
    socket =
      assign(socket,
        page_title: "Sign In",
        account: account,
        params: PortalWeb.Authentication.take_sign_in_params(params),
        google_auth_providers: auth_providers(account, Google.AuthProvider),
        okta_auth_providers: auth_providers(account, Okta.AuthProvider),
        entra_auth_providers: auth_providers(account, Entra.AuthProvider),
        oidc_auth_providers: auth_providers(account, OIDC.AuthProvider),
        email_otp_auth_provider: auth_providers(account, EmailOTP.AuthProvider),
        userpass_auth_provider: auth_providers(account, Userpass.AuthProvider)
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} />
    <.flash flash={@flash} kind={:info} />

    <%= if trial_ends_at = get_in(@account.metadata.stripe.trial_ends_at) do %>
      <% trial_ends_in_days = trial_ends_at |> DateTime.diff(DateTime.utc_now(), :day) %>

      <.flash :if={trial_ends_in_days <= 0} kind={:error}>
        Your trial has expired and needs to be renewed.
        Contact your account manager or administrator to ensure uninterrupted service.
      </.flash>
    <% end %>

    <div class="flex items-center gap-3 mb-8 mt-4">
      <div class="w-11 h-11 rounded bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center shrink-0">
        <span class="text-lg font-bold text-[var(--brand)]">
          {String.upcase(String.first(@account.name))}
        </span>
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Sign in to {@account.name}
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          Choose how you'd like to sign in.
        </p>
      </div>
    </div>

    <.intersperse_blocks>
      <:separator>
        <.separator />
      </:separator>

      <:item :if={
        Enum.any?(
          @google_auth_providers ++
            @okta_auth_providers ++ @entra_auth_providers ++ @oidc_auth_providers
        )
      }>
        <div class="flex flex-col gap-2">
          <.auth_button
            :for={provider <- @google_auth_providers}
            account={@account}
            params={@params}
            provider={provider}
            type="google"
          >
            <:icon>
              <img src={~p"/images/google-logo.svg"} alt="Google Workspace Logo" class="w-5 h-5" />
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
              <img src={~p"/images/okta-logo.svg"} alt="Okta Logo" class="w-5 h-5" />
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
              <img src={~p"/images/entra-logo.svg"} alt="Microsoft Entra Logo" class="w-5 h-5" />
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
              <.provider_icon type={provider_type_from_issuer(provider.issuer)} class="w-5 h-5" />
            </:icon>
          </.auth_button>
        </div>
      </:item>

      <:item :if={@email_otp_auth_provider}>
        <.email_form
          provider={@email_otp_auth_provider}
          account={@account}
          flash={@flash}
          params={@params}
        />
      </:item>

      <:item :if={@userpass_auth_provider}>
        <.userpass_form
          provider={@userpass_auth_provider}
          account={@account}
          flash={@flash}
          params={@params}
        />
      </:item>
    </.intersperse_blocks>

    <div :if={@params["as"] != "client"} class="mt-8 pt-6 border-t border-[var(--border)] text-center">
      <p class="text-xs text-[var(--text-tertiary)] leading-relaxed">
        Meant to sign in from a client instead?
        <.website_link path="/kb/client-apps">Read the docs.</.website_link>
      </p>
      <p class="text-xs text-[var(--text-tertiary)] mt-1.5">
        Looking for a different account?
        <.link href={~p"/"} class={[link_style()]}>See recently used accounts.</.link>
      </p>
    </div>
    """
  end

  def separator(assigns) do
    ~H"""
    <div class="flex items-center gap-3 my-5">
      <div class="flex-1 h-px bg-[var(--border)]"></div>
      <span class="text-xs text-[var(--text-muted)]">or</span>
      <div class="flex-1 h-px bg-[var(--border)]"></div>
    </div>
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
      class="w-full flex items-center gap-3 px-4 py-3 rounded border-2 border-[var(--border)] bg-[var(--surface)] hover:border-[var(--brand)] hover:shadow-sm transition-all duration-150 group text-sm font-medium text-[var(--text-primary)]"
      href={~p"/#{@account}/sign_in/#{@type}/#{@provider.id}?#{@params}"}
    >
      {render_slot(@icon)}
      <span class="flex-1">Continue with <strong>{@provider.name}</strong></span>
      <.icon
        name="ri-arrow-right-s-line"
        class="w-5 h-5 text-[var(--text-muted)] group-hover:text-[var(--brand)] group-hover:translate-x-0.5 transition-all shrink-0"
      />
    </.link>
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
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
      <input
        type="text"
        name="userpass[idp_id]"
        value={@userpass_form[:idp_id].value}
        placeholder="Username"
        class="w-full px-3 py-2 text-sm rounded border bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors placeholder:text-[var(--text-muted)]"
        required
      />
      <input
        type="password"
        name="userpass[secret]"
        placeholder="Password"
        class="w-full px-3 py-2 text-sm rounded border bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors placeholder:text-[var(--text-muted)]"
        required
      />
      <button
        type="submit"
        class="w-full py-2.5 rounded text-sm font-semibold bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors"
      >
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
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
      <div class="flex gap-2">
        <input
          type="email"
          name="email[email]"
          value={@email_form[:email].value}
          placeholder="you@example.com"
          class="flex-1 px-3 py-2 text-sm rounded border bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors placeholder:text-[var(--text-muted)]"
          required
        />
        <button
          type="submit"
          class="px-4 py-2 rounded text-sm font-semibold bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors whitespace-nowrap"
        >
          Send code →
        </button>
      </div>
    </.form>
    """
  end

  def adapter_enabled?(providers_by_adapter, adapter) do
    Map.get(providers_by_adapter, adapter, []) != []
  end

  defp auth_providers(account, module) do
    if module in [EmailOTP.AuthProvider, Userpass.AuthProvider] do
      Database.get_auth_provider(account, module)
    else
      Database.list_auth_providers(account, module)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id_or_slug!(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped(:replica) |> Safe.one!()
    end

    def get_auth_provider(account, module) do
      from(ap in module, where: ap.account_id == ^account.id and not ap.is_disabled)
      |> Safe.unscoped(:replica)
      |> Safe.one()
    end

    def list_auth_providers(account, module) do
      from(ap in module, where: ap.account_id == ^account.id and not ap.is_disabled)
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end
  end
end
