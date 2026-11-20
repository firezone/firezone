defmodule PortalWeb.SignInChooser do
  @moduledoc """
  The sign-in page before an account is known: the accounts recently signed in to from
  this browser, a form that emails the sign-in links of every account an email belongs to,
  and the account ID form.

  Clients signing in get the recent accounts and the sign-in URL form first. Their email
  form sends the sign-in URLs to enter here rather than links, because a link opened from
  the email would sign in a browser rather than the client. Clients never see sign-up.
  """
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database
  alias Phoenix.LiveView.JS
  alias PortalWeb.Components.Turnstile
  alias PortalWeb.EmailForm
  alias PortalWeb.PublicEmailRateLimit

  @doc """
  The session for the LiveView: the recent accounts that still exist, as left by
  `PortalWeb.Plugs.PruneRecentAccounts`.
  """
  @spec live_session(Plug.Conn.t()) :: map()
  def live_session(conn) do
    %{"recent_account_ids" => PortalWeb.Plugs.PruneRecentAccounts.account_ids(conn)}
  end

  def mount(_params, session, socket) do
    account_ids = Map.get(session, "recent_account_ids", [])

    {:ok,
     assign(socket,
       page_title: "Sign In",
       accounts: Database.get_accounts_by_ids(account_ids),
       real_ip: PortalWeb.Authentication.real_ip(socket),
       turnstile_error: nil
     ), temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  # A patch back to this page ("Try again") starts over with an empty form.
  def handle_params(params, _uri, socket) do
    sign_in_params = PortalWeb.Authentication.take_sign_in_params(params)

    {:noreply,
     assign(socket,
       params: sign_in_params,
       client_sign_in?: PortalWeb.Authentication.client_sign_in?(sign_in_params),
       step: :choose,
       submitted_email: nil,
       client_email_sent: nil,
       client_email_open?: false,
       turnstile_error: nil,
       form: to_form(EmailForm.changeset(), as: :email_form)
     )}
  end

  def render(assigns) do
    ~H"""
    <Core.flash flash={@flash} kind={:error} />
    <Core.flash flash={@flash} kind={:info} />

    <.chooser
      :if={@step == :choose}
      accounts={@accounts}
      params={@params}
      client_sign_in?={@client_sign_in?}
      form={@form}
      turnstile_error={@turnstile_error}
      client_email_sent={@client_email_sent}
      client_email_open?={@client_email_open?}
    />
    <.email_sent :if={@step == :email_sent} email={@submitted_email} params={@params} />
    """
  end

  attr :accounts, :list, required: true
  attr :params, :map, required: true
  attr :client_sign_in?, :boolean, required: true
  attr :form, :any, required: true
  attr :turnstile_error, :string, default: nil
  attr :client_email_sent, :string, default: nil
  attr :client_email_open?, :boolean, default: false

  defp chooser(assigns) do
    ~H"""
    <div class="text-center mb-6">
      <h1 class="text-2xl font-bold text-heading tracking-tight">Sign in</h1>
      <p class="text-sm text-subtle mt-1.5">
        {subtitle(@accounts, @client_sign_in?)}
      </p>
    </div>

    <div :if={@accounts != []} id="recent-accounts" class="mb-6">
      <.section_label>Recently signed in</.section_label>
      <div class="flex flex-col gap-2">
        <div :for={account <- @accounts} id={"recent-account-#{account.id}"} class="relative group/row">
          <Page.account_button
            account={account}
            href={~p"/#{account}/sign_in?#{@params}"}
            arrow={false}
            class="pr-14"
          />
          <%!--
            A plain form: removing an account changes a cookie, which a LiveView can't.
            It shows on hover or keyboard focus, and always on touch screens, which can't hover.
          --%>
          <.form
            for={%{}}
            action={~p"/sign_in/recent_accounts/#{account.id}/remove?#{@params}"}
            method="post"
            class="absolute right-3 top-1/2 -translate-y-1/2 opacity-0 group-hover/row:opacity-100 focus-within:opacity-100 pointer-coarse:opacity-100 transition-opacity"
          >
            <button
              type="submit"
              aria-label={"Remove #{account.name} from recent accounts"}
              title="Remove from recent accounts"
              class="w-9 h-9 rounded flex items-center justify-center text-subtle hover:text-heading hover:bg-raised transition-colors"
            >
              <Core.icon name="ri-close-line" class="w-4 h-4" />
            </button>
          </.form>
        </div>
      </div>
    </div>

    <div :if={@client_sign_in?} id="client-sign-in">
      <div id="account-slug">
        <Page.account_slug_form action={~p"/sign_in?#{@params}"} autofocus={@accounts == []} />
      </div>

      <%!-- The email confirmation replaces the email form, so the sign-in URL form above stays put --%>
      <div id="client-email-section" class="mt-6">
        <div
          :if={@client_email_sent}
          id="client-email-sent"
          role="status"
          class="rounded border border-border bg-raised p-4 text-center"
        >
          <p class="text-sm font-medium text-heading">Check your inbox</p>
          <p class="text-sm text-subtle mt-1">
            If <span class="font-medium text-body">{@client_email_sent}</span>
            is registered, we've sent you your sign-in URL. Enter it above when it arrives.
          </p>
          <p class="text-sm text-subtle mt-3">
            Wrong address?
            <button type="button" id="client-email-retry" phx-click="retry_client_email" class={Core.link_style()}>
              Try again
            </button>
          </p>
        </div>

        <%= if !@client_email_sent do %>
          <%!-- Clicking the link swaps it for the email form --%>
          <p
            id="client-email-prompt"
            class={["text-center text-sm text-subtle", client_email_open?(assigns) && "hidden"]}
          >
            Forgot your sign-in URL?
            <button
              type="button"
              id="client-email-toggle"
              aria-controls="client-email"
              phx-click={
                JS.hide(to: "#client-email-prompt")
                |> JS.show(to: "#client-email")
                |> JS.focus(to: "#client-email input[type=email]")
              }
              class={Core.link_style()}
            >
              Email it to me
            </button>
          </p>
          <div id="client-email" class={[!client_email_open?(assigns) && "hidden"]}>
            <.email_form form={@form} turnstile_error={@turnstile_error} autofocus={@client_email_open?} />
          </div>
        <% end %>
      </div>
    </div>

    <div :if={!@client_sign_in?} id="find-accounts">
      <.email_form form={@form} turnstile_error={@turnstile_error} autofocus={@accounts == []} />

      <div id="account-slug-section" class="mt-6">
        <%!-- Clicking the link swaps it for the form --%>
        <p id="account-slug-prompt" class="text-center text-sm text-subtle">
          Know your sign-in URL?
          <button
            type="button"
            id="account-slug-toggle"
            aria-controls="account-slug"
            phx-click={
              JS.hide(to: "#account-slug-prompt")
              |> JS.show(to: "#account-slug")
              |> JS.focus(to: "#account-slug input[type=text]")
            }
            class={Core.link_style()}
          >
            Enter it instead
          </button>
        </p>
        <div id="account-slug" class="hidden mb-3">
          <Page.account_slug_form action={~p"/sign_in?#{@params}"} autofocus={false} />
        </div>
        <p id="sign-up-link" class="mt-1 text-center text-sm text-subtle">
          New to Firezone? <Navigation.link href={~p"/sign_up"}>Sign up</Navigation.link>
        </p>
      </div>
    </div>
    """
  end

  # The client's email form opens in the browser. It stays open once the person has typed in
  # it, a submission failed, or they chose to try again, so errors are never hidden.
  defp client_email_open?(assigns) do
    assigns.client_email_open? or assigns.form.params != %{} or assigns.turnstile_error != nil
  end

  defp subtitle([], true), do: "Enter your organization's sign-in URL to continue."
  defp subtitle(_accounts, true), do: "Choose your organization to continue."
  defp subtitle([], false), do: "Enter your email and we'll send you a sign-in link."
  defp subtitle(_accounts, false), do: "Pick up where you left off or get a sign-in link by email."

  slot :inner_block, required: true

  defp section_label(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-3">
      <div class="flex-1 h-px bg-border"></div>
      <span class="text-xs font-medium text-subtle uppercase tracking-widest">
        {render_slot(@inner_block)}
      </span>
      <div class="flex-1 h-px bg-border"></div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :turnstile_error, :string, default: nil
  attr :autofocus, :boolean, default: false

  defp email_form(assigns) do
    ~H"""
    <.form id="find-account-form" for={@form} phx-submit="submit_email" phx-change="validate_email">
      <label for={@form[:email].id} class="block text-xs font-semibold text-body mb-1.5">
        Work email
      </label>
      <div class="flex gap-2">
        <div class="flex-1 min-w-0">
          <Form.input
            field={@form[:email]}
            type="email"
            placeholder="you@company.com"
            required
            autofocus={@autofocus}
            phx-debounce="300"
          />
        </div>
        <button
          type="submit"
          phx-disable-with="Sending..."
          class="px-4 py-2 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors whitespace-nowrap self-start"
        >
          Email me
        </button>
      </div>

      <Turnstile.widget id="find-account-turnstile-widget" />
      <Turnstile.token_input id="find-account-turnstile-token" />
      <p :if={@turnstile_error} id="turnstile-form-error" role="alert" class="text-sm text-error">
        {@turnstile_error}
      </p>
    </.form>
    """
  end

  attr :email, :string, required: true
  attr :params, :map, required: true

  defp email_sent(assigns) do
    ~H"""
    <div class="text-center mb-6">
      <h1 class="text-2xl font-bold text-heading tracking-tight">Check your inbox</h1>
      <p class="text-sm text-subtle mt-1.5">
        If <span class="font-medium text-body">{@email}</span>
        is registered, we've sent you a sign-in link.
      </p>
    </div>

    <ol class="rounded border border-border bg-raised p-4 space-y-4">
      <li class="flex gap-3">
        <.step_number>1</.step_number>
        <div>
          <p class="text-sm font-medium text-heading">Open the email from Firezone</p>
          <p class="text-xs text-subtle mt-0.5 leading-relaxed">
            It should arrive within a minute or two. Check your spam folder too.
          </p>
        </div>
      </li>
      <li class="flex gap-3">
        <.step_number>2</.step_number>
        <div>
          <p class="text-sm font-medium text-heading">Click the sign-in link</p>
          <p class="text-xs text-subtle mt-0.5 leading-relaxed">
            It opens your organization's sign-in page.
          </p>
        </div>
      </li>
    </ol>

    <p class="mt-6 text-center text-sm text-subtle">
      Wrong address? <Navigation.link patch={~p"/sign_in?#{@params}"}>Try again</Navigation.link>
    </p>
    """
  end

  slot :inner_block, required: true

  defp step_number(assigns) do
    ~H"""
    <div class="shrink-0 w-6 h-6 rounded-full bg-brand/10 border border-brand/20 flex items-center justify-center">
      <span class="text-xs font-bold text-brand">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  # Brings back the client's email form, open, in place of the confirmation.
  def handle_event("retry_client_email", _params, socket) do
    {:noreply,
     assign(socket,
       client_email_sent: nil,
       client_email_open?: true,
       form: to_form(EmailForm.changeset(), as: :email_form)
     )}
  end

  def handle_event("validate_email", %{"email_form" => attrs}, socket) do
    changeset = EmailForm.changeset(attrs) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :email_form), turnstile_error: nil)}
  end

  def handle_event("submit_email", %{"email_form" => attrs} = params, socket) do
    changeset = EmailForm.changeset(attrs) |> Map.put(:action, :insert)
    {:noreply, submit_email(socket, changeset, params["cf-turnstile-response"])}
  end

  # An invalid form is sent back before the challenge is checked, so a typo does not spend
  # the single-use token.
  defp submit_email(socket, %{valid?: false} = changeset, _token) do
    assign(socket, form: to_form(changeset, as: :email_form))
  end

  defp submit_email(socket, changeset, token) do
    case Portal.Turnstile.verify(token, socket.assigns.real_ip) do
      :ok ->
        socket |> assign(turnstile_error: nil) |> send_email(changeset) |> reset_turnstile()

      {:error, reason} ->
        socket
        |> assign(form: to_form(changeset, as: :email_form), turnstile_error: Turnstile.error_message(reason))
        |> Turnstile.reset()
    end
  end

  defp send_email(socket, changeset) do
    email = Ecto.Changeset.get_field(changeset, :email)

    case PublicEmailRateLimit.check(:find_account, socket.assigns.real_ip) do
      :ok ->
        deliver_accounts_email(email, socket.assigns.client_sign_in?)
        email_sent(socket, email)

      {:error, :rate_limited} ->
        changeset = Ecto.Changeset.add_error(changeset, :email, "Too many attempts. Please try again later.")
        assign(socket, form: to_form(changeset, as: :email_form))
    end
  end

  # Clients stay on this page, where they enter the sign-in URL from the email.
  defp email_sent(%{assigns: %{client_sign_in?: true}} = socket, email),
    do: assign(socket, client_email_sent: email, client_email_open?: false)

  defp email_sent(socket, email), do: assign(socket, step: :email_sent, submitted_email: email)

  # Clients get the sign-in URLs to enter on this page, and no sign-up offer.
  defp deliver_accounts_email(email, client_sign_in?) do
    rate_limit_opts = [
      rate_limit_key: {:find_account, String.downcase(email)},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(30)
    ]

    case Database.find_accounts_by_actor_email(email) do
      [] ->
        sign_up_url = if client_sign_in?, do: nil, else: url(~p"/sign_up")

        Portal.Mailer.AuthEmail.no_accounts_found_email(email, sign_up_url)
        |> Portal.Mailer.deliver_with_rate_limit(rate_limit_opts)

      accounts ->
        accounts_with_urls = Enum.map(accounts, &{&1, account_url(&1, client_sign_in?)})

        Portal.Mailer.AuthEmail.existing_accounts_email(email, accounts_with_urls, client: client_sign_in?)
        |> Portal.Mailer.deliver_with_rate_limit(rate_limit_opts)
    end
  end

  # The URL to enter in the sign-in URL form for clients, the sign-in page for browsers.
  defp account_url(account, true), do: url(~p"/#{account.slug}")
  defp account_url(account, false), do: url(~p"/#{account.slug}/sign_in")

  defp reset_turnstile(%{assigns: %{step: :email_sent}} = socket), do: socket
  defp reset_turnstile(%{assigns: %{client_email_sent: email}} = socket) when is_binary(email), do: socket
  defp reset_turnstile(socket), do: Turnstile.reset(socket)

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    @doc "The accounts with these ids, in the order of the ids."
    @spec get_accounts_by_ids([Ecto.UUID.t()]) :: [Portal.Account.t()]
    def get_accounts_by_ids([]), do: []

    def get_accounts_by_ids(account_ids) do
      accounts =
        from(a in Portal.Account, where: a.id in ^account_ids)
        |> Safe.unscoped()
        |> Safe.all()
        |> Map.new(&{&1.id, &1})

      account_ids |> Enum.map(&Map.get(accounts, &1)) |> Enum.reject(&is_nil/1)
    end

    @spec find_accounts_by_actor_email(String.t()) :: [Portal.Account.t()]
    def find_accounts_by_actor_email(email) do
      from(acc in Portal.Account,
        join: a in Portal.Actor,
        on: a.account_id == acc.id,
        where: a.email == ^email,
        distinct: true
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
