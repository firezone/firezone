defmodule PortalWeb.SignIn.Email do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :public}}
  alias __MODULE__.Database

  def mount(
        %{
          "account_id_or_slug" => account_id_or_slug,
          "auth_provider_id" => provider_id
        } = params,
        session,
        socket
      ) do
    redirect_params = PortalWeb.Authentication.take_sign_in_params(params)

    account = Database.get_account_by_id_or_slug(account_id_or_slug)

    with %Portal.Account{} = account <- account,
         {:ok, email} <- Map.fetch(session, "email") do
      form = to_form(%{"secret" => nil})

      verify_action = ~p"/#{account_id_or_slug}/sign_in/email_otp/#{provider_id}/verify"
      resend_action = ~p"/#{account_id_or_slug}/sign_in/email_otp/#{provider_id}?resend=true"

      socket =
        assign(socket,
          form: form,
          email: email,
          account_id_or_slug: account_id_or_slug,
          account: account,
          provider_id: provider_id,
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
          |> push_navigate(to: ~p"/")

        {:ok, socket}

      _ ->
        socket =
          socket
          |> put_flash(:error, "Please try to sign in again.")
          |> push_navigate(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

        {:ok, socket}
    end
  end

  def mount(_params, _session, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.hero_logo text={@account.name} />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl leading-tight tracking-tight text-neutral-900 sm:text-2xl">
              Please check your email
            </h1>
            <.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />
            <.flash flash={@flash} kind={:info} phx-click={JS.hide(transition: "fade-out")} />

            <div>
              <p>
                If <strong>{@email}</strong> is registered, a sign-in code has been sent.
              </p>
              <form
                id="verify-sign-in-token"
                action={@verify_action}
                method="post"
                class="my-4 flex"
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

                <input
                  type="text"
                  name="secret"
                  id="secret"
                  class={[
                    "block p-2.5 w-full text-sm",
                    "bg-neutral-50 text-neutral-900",
                    "rounded-l border-neutral-300"
                  ]}
                  required
                  placeholder="Enter code from email"
                />

                <button
                  type="submit"
                  class={[
                    "block p-2.5",
                    "text-sm text-white",
                    "items-center text-center",
                    "bg-accent-600 rounded-r",
                    "hover:bg-accent-700"
                  ]}
                >
                  Submit
                </button>
              </form>
              <.resend
                resend_action={@resend_action}
                email={@email}
                redirect_params={@redirect_params}
              /> or
              <.link navigate={~p"/#{@account_id_or_slug}?#{@redirect_params}"} class={link_style()}>
                use a different Sign In method
              </.link>
              .
            </div>
            <div class="flex">
              <.dev_email_provider_link url="https://mail.google.com/mail/" name="Gmail" />
              <.email_provider_link url="https://mail.google.com/mail/" name="Gmail" />
              <.email_provider_link url="https://outlook.live.com/mail/" name="Outlook" />
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def handle_info(:hide_resent_flash, socket) do
    {:noreply, assign(socket, :resent, nil)}
  end

  if Mix.env() in [:dev, :test] do
    defp dev_email_provider_link(assigns) do
      ~H"""
      <.email_provider_link url={~p"/dev/mailbox"} name="Local" />
      """
    end
  else
    defp dev_email_provider_link(assigns), do: ~H""
  end

  defp resend(assigns) do
    ~H"""
    <.form
      for={%{}}
      id="resend-email"
      as={:email}
      class="inline"
      action={@resend_action}
      method="post"
    >
      <.input type="hidden" name="email[email]" value={@email} />
      <.input :for={{key, value} <- @redirect_params} type="hidden" name={key} value={value} />
      <span>
        Did not receive it?
        <button type="submit" class="inline text-accent-500 hover:underline">
          Resend email
        </button>
      </span>
    </.form>
    """
  end

  defp email_provider_link(assigns) do
    ~H"""
    <a
      href={@url}
      class={[
        "w-1/2 m-2 inline-flex items-center justify-center py-2.5 px-5",
        "text-sm text-neutral-900 bg-white ",
        "rounded border border-neutral-200",
        "hover:text-neutral-900 hover:bg-neutral-100"
      ]}
    >
      Open {@name}
    </a>
    """
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      query |> Portal.Repo.fetch_unscoped(:one)
    end
  end
end
