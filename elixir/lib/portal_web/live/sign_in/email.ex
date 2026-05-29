defmodule PortalWeb.SignIn.Email do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database

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

    account = Database.get_account_by_id_or_slug(account_id_or_slug)

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
          |> redirect(to: ~p"/")

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
    <.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />
    <.flash flash={@flash} kind={:info} phx-click={JS.hide(transition: "fade-out")} />

    <h1 class="text-xl font-semibold text-heading mb-2">
      Check your email
    </h1>
    <p :if={@pending_identity?} class="text-sm text-body mb-6">
      A verification code has been sent to your email address.
    </p>
    <p :if={!@pending_identity?} class="text-sm text-body mb-6">
      If <strong class="text-heading">{@email}</strong>
      is registered, a sign-in code has been sent.
    </p>

    <form
      id="verify-sign-in-token"
      action={@verify_action}
      method="post"
      phx-update="ignore"
      phx-hook="AttachDisableSubmit"
      phx-submit={JS.dispatch("form:disable_and_submit", to: "#verify-sign-in-token")}
    >
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <.input
        :for={{key, value} <- @redirect_params}
        type="hidden"
        name={key}
        value={value}
      />

      <div
        id="pin-input"
        phx-hook="PINInput"
        phx-update="ignore"
        class="flex gap-3 justify-center mb-6"
      >
        <input
          :for={i <- 0..4}
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

    <div class={["mt-4 grid gap-2", if(@resend_action, do: "grid-cols-2", else: "grid-cols-1")]}>
      <.link
        href={~p"/#{@account_id_or_slug}?#{@redirect_params}"}
        class="relative flex items-center justify-center px-4 py-2.5 rounded-md border border-border-strong bg-surface hover:bg-raised transition-colors text-sm font-medium text-heading"
      >
        <.icon name="ri-arrow-left-line" class="absolute left-4 w-4 h-4 text-body" />
        Different method
      </.link>
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
        class="mt-2 flex items-center justify-center gap-2 px-4 py-2.5 rounded-md border border-border-strong bg-surface hover:bg-raised transition-colors text-sm font-medium text-heading"
      >
        <.icon name="ri-mail-open-line" class="w-4 h-4 text-body shrink-0" />
        Open local mailbox
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
    """
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped(:replica) |> Safe.one()
    end
  end
end
