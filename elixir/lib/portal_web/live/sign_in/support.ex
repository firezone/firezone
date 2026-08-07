defmodule PortalWeb.SignIn.Support do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database

  def mount(%{"account_id_or_slug" => account_id_or_slug} = params, session, socket) do
    account = Database.get_account_by_id_or_slug(account_id_or_slug)

    if is_nil(account) or is_nil(Database.get_active_support_provider(account)) do
      raise PortalWeb.LiveErrors.NotFoundError
    end

    redirect_params = PortalWeb.Authentication.take_sign_in_params(params)

    socket =
      assign(socket,
        account: account,
        account_id_or_slug: account_id_or_slug,
        redirect_params: redirect_params,
        resent: params["resent"],
        webauthn_error: nil,
        page_title: "Firezone Support"
      )

    case check_stage(socket.assigns.live_action, session, account) do
      :ok ->
        {:ok, assign_stage(socket, session)}

      :error ->
        socket =
          socket
          |> put_flash(:error, "Please try to sign in again.")
          |> redirect(to: ~p"/#{account_id_or_slug}/support?#{redirect_params}")

        {:ok, socket}
    end
  end

  def mount(_params, _session, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def render(%{live_action: :email} = assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />

    <h1 class="text-xl font-semibold text-heading mb-2">
      Firezone Support
    </h1>
    <p class="text-sm text-body mb-6">
      This sign-in method is used by Firezone Support to securely access your account.
    </p>

    <.form
      for={@form}
      action={~p"/#{@account_id_or_slug}/support"}
      id="support_email_form"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#support_email_form")}
    >
      <.input :for={{key, value} <- @redirect_params} type="hidden" name={key} value={value} />
      <div class="flex gap-2">
        <input
          type="email"
          name="email[email]"
          value={@form[:email].value}
          placeholder="you@firezone.dev"
          class="flex-1 px-3 py-2 text-sm rounded border bg-input border-input-border text-heading outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors placeholder:text-muted"
          required
        />
        <button
          type="submit"
          class="px-4 py-2 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors whitespace-nowrap"
        >
          Send code →
        </button>
      </div>
    </.form>
    """
  end

  def render(%{live_action: :verify_otp} = assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />
    <.flash flash={@flash} kind={:info} phx-click={JS.hide(transition: "fade-out")} />

    <h1 class="text-xl font-semibold text-heading mb-2">
      Check your email
    </h1>
    <p class="text-sm text-body mb-6">
      If <strong class="text-heading">{@email}</strong>
      is a registered support admin, a sign-in code has been sent.
    </p>

    <form
      id="verify-support-code"
      action={~p"/#{@account_id_or_slug}/support/verify"}
      method="post"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#verify-support-code")}
    >
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <.input :for={{key, value} <- @redirect_params} type="hidden" name={key} value={value} />

      <div id="pin-input" phx-hook="PINInput" phx-update="ignore" class="flex gap-3 justify-center mb-6">
        <input
          :for={i <- 0..5}
          data-pin-index={i}
          type="text"
          maxlength="1"
          inputmode="text"
          autocomplete="off"
          class="w-12 h-14 text-center text-xl font-semibold rounded-md border bg-input border-input-border text-heading outline-none focus:border-border-focus focus:ring-2 focus:ring-border-focus/30 transition-colors uppercase"
        />
        <input type="hidden" name="secret" id="secret" />
      </div>

      <button
        type="submit"
        class="w-full px-3 py-2.5 rounded-md text-sm font-medium bg-brand text-white hover:bg-brand-dark transition-colors"
      >
        Verify code
      </button>
    </form>

    <div class="mt-4">
      <.form
        for={%{}}
        id="resend-support-email"
        as={:email}
        action={~p"/#{@account_id_or_slug}/support?resend=true"}
        method="post"
      >
        <.input type="hidden" name="email[email]" value={@email} />
        <.input :for={{key, value} <- @redirect_params} type="hidden" name={key} value={value} />
        <button
          type="submit"
          class="relative w-full flex items-center justify-center px-4 py-2.5 rounded-md border border-border-strong bg-surface hover:bg-raised transition-colors text-sm font-medium text-heading"
        >
          <.icon name="ri-loop-left-line" class="absolute left-4 w-4 h-4 text-body" />
          Resend email
        </button>
      </.form>
    </div>
    """
  end

  def render(%{live_action: :passkey} = assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />

    <h1 class="text-xl font-semibold text-heading mb-2">
      Verify your passkey
    </h1>
    <p class="text-sm text-body mb-6">
      Complete sign-in for <strong class="text-heading">{@email}</strong> with your passkey.
    </p>

    <p :if={@webauthn_error} class="text-sm text-red-600 dark:text-red-400 mb-6">
      {@webauthn_error}
    </p>

    <form id="support-passkey-form" action={~p"/#{@account_id_or_slug}/support/complete"} method="post">
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <.input :for={{key, value} <- @redirect_params} type="hidden" name={key} value={value} />
      <input type="hidden" name="credential_id" value="" />
      <input type="hidden" name="authenticator_data" value="" />
      <input type="hidden" name="signature" value="" />
      <input type="hidden" name="client_data_json" value="" />
    </form>

    <button
      id="webauthn-authenticate"
      type="button"
      phx-hook="WebAuthnAuthenticate"
      phx-update="ignore"
      data-challenge={@challenge_bytes}
      data-credential-id={@credential_id}
      data-rp-id={@rp_id}
      data-form-id="support-passkey-form"
      class="w-full px-3 py-2.5 rounded-md text-sm font-medium bg-brand text-white hover:bg-brand-dark transition-colors"
    >
      Use passkey
    </button>
    """
  end

  def handle_event("webauthn_error", %{"error" => error}, socket) do
    {:noreply, assign(socket, webauthn_error: webauthn_error_message(error))}
  end

  defp check_stage(:email, _session, _account), do: :ok

  defp check_stage(:verify_otp, session, account) do
    if session["support_stage"] == "otp" and session["support_account_id"] == account.id do
      :ok
    else
      :error
    end
  end

  defp check_stage(:passkey, session, account) do
    if session["support_stage"] == "passkey" and session["support_account_id"] == account.id and
         is_binary(session["support_challenge_bytes"]) do
      :ok
    else
      :error
    end
  end

  defp assign_stage(%{assigns: %{live_action: :email}} = socket, _session) do
    assign(socket, form: to_form(%{"email" => nil}, as: "email"))
  end

  defp assign_stage(%{assigns: %{live_action: :verify_otp}} = socket, session) do
    assign(socket, email: session["support_email"])
  end

  defp assign_stage(%{assigns: %{live_action: :passkey}} = socket, session) do
    assign(socket,
      email: session["support_email"],
      challenge_bytes: session["support_challenge_bytes"],
      credential_id: session["support_credential_id"],
      rp_id: Portal.Crypto.WebAuthn.rp_id()
    )
  end

  defp webauthn_error_message("unsupported"), do: "This browser doesn't support passkeys."

  defp webauthn_error_message("NotAllowedError"),
    do: "Passkey verification was cancelled or timed out. Try again."

  defp webauthn_error_message(_other), do: "Passkey verification failed. Try again."

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.{Account, FirezoneSupport}

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped() |> Safe.one()
    end

    def get_active_support_provider(account) do
      from(p in FirezoneSupport.AuthProvider,
        where: p.account_id == ^account.id,
        where: p.expires_at > ^DateTime.utc_now()
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
