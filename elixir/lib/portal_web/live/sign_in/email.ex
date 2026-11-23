defmodule PortalWeb.SignIn.Email do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias PortalWeb.Components.AuthPage

  def mount(
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => provider_id
        } = params,
        session,
        socket
      ) do
    redirect_params =
      params
      |> PortalWeb.Authentication.take_sign_in_params()
      |> Map.merge(PortalWeb.Authentication.take_sign_in_params(session))

    account = PortalWeb.Accounts.get_by_id_or_slug(account_id_or_slug)

    with %Portal.Account{} = account <- account,
         {:ok, email} <- fetch_email(socket.assigns.live_action, account, session) do
      form = to_form(%{"secret" => nil})
      pending_identity? = socket.assigns.live_action == :pending_identity
      pending_identity_id = Map.get(session, "pending_identity_id")

      verify_action =
        verify_action(
          socket.assigns.live_action,
          account_id_or_slug,
          provider_id,
          pending_identity_id
        )

      resend_action = resend_action(socket.assigns.live_action, account_id_or_slug, provider_id)

      socket =
        assign(socket,
          form: form,
          email: email,
          account_id_or_slug: account_id_or_slug,
          account: account,
          provider_id: provider_id,
          pending_identity?: pending_identity?,
          resent: params["resent"],
          redirect_params: redirect_params,
          verify_action: verify_action,
          resend_action: resend_action,
          page_title: "Sign In"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      nil ->
        socket =
          socket
          |> put_flash(:error, "Account not found.")
          |> redirect(to: ~p"/sign_in")

        {:ok, socket}

      _ ->
        socket =
          socket
          |> put_flash(:error, "Please try to sign in again.")
          |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

        {:ok, socket}
    end
  end

  def mount(_params, _session, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def render(assigns) do
    ~H"""
    <Core.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />
    <Core.flash flash={@flash} kind={:info} phx-click={JS.hide(transition: "fade-out")} />

    <AuthPage.heading title="Check your email">
      <span :if={@pending_identity?}>
        A verification code has been sent to your email address.
      </span>
      <span :if={!@pending_identity?}>
        If <strong class="font-semibold text-fg">{@email}</strong>
        is registered, a sign-in code has been sent.
      </span>
    </AuthPage.heading>

    <form
      id="verify-sign-in-token"
      action={@verify_action}
      method="post"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#verify-sign-in-token")}
    >
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <Form.input
        :for={{key, value} <- @redirect_params}
        type="hidden"
        name={key}
        value={value}
      />

      <div
        id="pin-input"
        phx-hook="PINInput"
        phx-update="ignore"
        class="grid grid-cols-6 gap-2 mb-6"
      >
        <input
          :for={i <- 0..5}
          data-pin-index={i}
          type="text"
          maxlength="1"
          inputmode="text"
          autocomplete="off"
          aria-label={"Code character #{i + 1}"}
          class="w-full h-14 p-0 text-center font-mono text-2xl font-bold uppercase bg-bg text-fg border border-rule outline-none transition-colors focus:ring-2 focus:ring-fg focus:border-fg"
        />
        <input type="hidden" name="secret" id="secret" />
      </div>

      <button type="submit" class={[AuthPage.primary_button_class(), "w-full"]}>
        Verify code
      </button>
    </form>

    <div class={["mt-3 grid gap-2", if(@resend_action, do: "grid-cols-2", else: "grid-cols-1")]}>
      <Navigation.link
        href={~p"/#{@account_id_or_slug}?#{@redirect_params}"}
        class={[AuthPage.outline_button_class(), "w-full"]}
      >
        <Core.icon name="ri-arrow-left-line" class="w-4 h-4 text-muted" /> Different method
      </Navigation.link>
      <.resend
        :if={@resend_action}
        resend_action={@resend_action}
        email={@email}
        redirect_params={@redirect_params}
      />
    </div>

    <.dev_mailbox_link />
    """
  end

  defp verify_action(:pending_identity, account_id_or_slug, provider_id, pending_identity_id),
    do:
      ~p"/#{account_id_or_slug}/sign_in/oidc/#{provider_id}/verify_identity?pending_identity_id=#{pending_identity_id}"

  defp verify_action(_live_action, account_id_or_slug, provider_id, _pending_identity_id),
    do: ~p"/#{account_id_or_slug}/sign_in/email_otp/#{provider_id}/verify"

  defp resend_action(:pending_identity, _account_id_or_slug, _provider_id), do: nil

  defp resend_action(_live_action, account_id_or_slug, provider_id),
    do: ~p"/#{account_id_or_slug}/sign_in/email_otp/#{provider_id}?resend=true"

  defp fetch_email(:pending_identity, _account, session) do
    case Map.fetch(session, "pending_identity_id") do
      {:ok, _pending_identity_id} -> {:ok, nil}
      :error -> :error
    end
  end

  defp fetch_email(_live_action, _account, session), do: Map.fetch(session, "email")

  def handle_info(:hide_resent_flash, socket) do
    {:noreply, assign(socket, :resent, nil)}
  end

  if Mix.env() in [:dev, :test] do
    defp dev_mailbox_link(assigns) do
      ~H"""
      <a
        href={~p"/dev/mailbox"}
        target="_blank"
        class={[AuthPage.outline_button_class(), "w-full mt-2 border-dashed"]}
      >
        <Core.icon name="ri-mail-open-line" class="w-4 h-4 text-muted shrink-0" /> Open local mailbox
      </a>
      """
    end
  else
    defp dev_mailbox_link(assigns), do: ~H""
  end

  defp resend(assigns) do
    ~H"""
    <.form
      for={%{}}
      id="resend-email"
      as={:email}
      action={@resend_action}
      method="post"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#resend-email")}
    >
      <Form.input type="hidden" name="email[email]" value={@email} />
      <Form.input :for={{key, value} <- @redirect_params} type="hidden" name={key} value={value} />
      <button type="submit" class={[AuthPage.outline_button_class(), "w-full"]}>
        <Core.icon name="ri-loop-left-line" class="w-4 h-4 text-muted" />
        <span data-disable-with="Sending...">Resend email</span>
      </button>
    </.form>
    """
  end

end
