defmodule Web.SignIn.Email do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  def mount(
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "provider_identifier" => provider_identifier
        } = params,
        _session,
        socket
      ) do
    form = to_form(%{"secret" => nil})

    params = Web.Auth.take_sign_in_params(params)

    socket =
      assign(socket,
        form: form,
        provider_identifier: provider_identifier,
        account_id_or_slug: account_id_or_slug,
        provider_id: provider_id,
        resent: params["resent"],
        params: params
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl leading-tight tracking-tight text-neutral-900 sm:text-2xl">
              Please check your email
            </h1>
            <.flash flash={@flash} kind={:error} phx-click={JS.hide(transition: "fade-out")} />
            <.flash flash={@flash} kind={:info} phx-click={JS.hide(transition: "fade-out")} />

            <div>
              <p>
                Should the provided email be registered, a sign in token has been sent to your email account.
                Please copy and paste this into the form below to proceed with your login.
              </p>
              <form
                id="verify-sign-in-token"
                action={
                  ~p"/#{@account_id_or_slug}/sign_in/providers/#{@provider_id}/verify_sign_in_token"
                }
                method="get"
                class="my-4 flex"
              >
                <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
                <.input type="hidden" name="identity_id" value={@provider_identifier} />

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
                  placeholder="Enter token from email"
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
                account_id_or_slug={@account_id_or_slug}
                provider_id={@provider_id}
                provider_identifier={@provider_identifier}
                params={@params}
              /> or
              <.link navigate={~p"/#{@account_id_or_slug}?#{@params}"} class={link_style()}>
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
      action={
        ~p"/#{@account_id_or_slug}/sign_in/providers/#{@provider_id}/request_magic_link?resend=true"
      }
      method="post"
    >
      <.input type="hidden" name="email[provider_identifier]" value={@provider_identifier} />
      <.input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
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
      Open <%= @name %>
    </a>
    """
  end
end
