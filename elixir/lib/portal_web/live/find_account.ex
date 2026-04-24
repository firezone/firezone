defmodule PortalWeb.FindAccount do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database

  # ── Email form schema ─────────────────────────────────────────────────────────

  defmodule EmailForm do
    use Ecto.Schema
    @primary_key false

    import Ecto.Changeset
    import Portal.Changeset

    embedded_schema do
      field(:email, :string)
    end

    @spec changeset(map()) :: Ecto.Changeset.t()
    def changeset(attrs \\ %{}) do
      whitelisted_domains = Portal.Config.get_env(:portal, :sign_up_whitelisted_domains)

      %__MODULE__{}
      |> cast(attrs, [:email])
      |> validate_required([:email])
      |> trim_change(:email)
      |> validate_email(:email)
      |> validate_email_allowed(whitelisted_domains)
    end

    defp validate_email_allowed(changeset, []), do: changeset

    defp validate_email_allowed(changeset, whitelisted_domains) do
      validate_change(changeset, :email, fn :email, email ->
        if email_allowed?(email, whitelisted_domains),
          do: [],
          else: [email: "this email domain is not allowed at this time"]
      end)
    end

    defp email_allowed?(email, whitelisted_domains) do
      with [_, domain] <- String.split(email, "@", parts: 2) do
        Enum.member?(whitelisted_domains, domain)
      else
        _ -> false
      end
    end
  end

  # ── Mount & params ────────────────────────────────────────────────────────────

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Find your organization",
       step: :enter_email,
       submitted_email: nil,
       form: to_form(EmailForm.changeset(), as: :email_form)
     ), temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} />
    <.flash flash={@flash} kind={:info} />

    <.email_form :if={@step == :enter_email} form={@form} />
    <.email_sent :if={@step == :email_sent} email={@submitted_email} />
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  defp email_form(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-violet-50 dark:bg-violet-950/30 border border-violet-200 dark:border-violet-800 flex items-center justify-center shrink-0">
        <.icon name="ri-team-line" class="w-5 h-5 text-violet-500 dark:text-violet-400" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Find your company's account
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          We'll send you a link to your organization's sign-in page.
        </p>
      </div>
    </div>

    <.form for={@form} phx-submit="submit_email" phx-change="validate_email">
      <label class="block text-xs font-semibold text-[var(--text-secondary)] mb-1.5">
        Work email
      </label>
      <div class="flex gap-2">
        <div class="flex-1">
          <.input
            field={@form[:email]}
            type="email"
            placeholder="you@company.com"
            required
            autofocus
            phx-debounce="300"
          />
        </div>
        <button
          type="submit"
          phx-disable-with="Finding..."
          class="px-4 py-2 rounded text-sm font-semibold bg-violet-600 text-white hover:bg-violet-700 transition-colors whitespace-nowrap self-start"
        >
          Find →
        </button>
      </div>
    </.form>

    <div class="mt-8 pt-6 border-t border-[var(--border)] text-center space-y-1.5">
      <p class="text-xs text-[var(--text-tertiary)]">
        Not sure where to start?
        <.link href={~p"/getting_started"} class={[link_style()]}>Let's get started.</.link>
      </p>
    </div>
    """
  end

  attr :email, :string, required: true

  defp email_sent(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-violet-50 dark:bg-violet-950/30 border border-violet-200 dark:border-violet-800 flex items-center justify-center shrink-0">
        <.icon name="ri-mail-line" class="w-5 h-5 text-violet-500 dark:text-violet-400" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">Check your inbox</h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          We've sent a message to <span class="font-medium text-[var(--text-secondary)]">{@email}</span>.
        </p>
      </div>
    </div>

    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-6">
      <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest mb-4">
        What to expect
      </p>
      <ol class="space-y-4">
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-violet-500/10 dark:bg-violet-400/10 border border-violet-500/20 dark:border-violet-400/20 flex items-center justify-center">
            <span class="text-xs font-bold text-violet-500 dark:text-violet-400">1</span>
          </div>
          <div>
            <p class="text-sm font-medium text-[var(--text-primary)]">Open the email from Firezone</p>
            <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
              Check your inbox — and spam folder — for a message from Firezone. It should arrive within a minute or two.
            </p>
          </div>
        </li>
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-violet-500/10 dark:bg-violet-400/10 border border-violet-500/20 dark:border-violet-400/20 flex items-center justify-center">
            <span class="text-xs font-bold text-violet-500 dark:text-violet-400">2</span>
          </div>
          <div>
            <p class="text-sm font-medium text-[var(--text-primary)]">
              Follow the instructions inside
            </p>
            <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
              If we found accounts linked to your email, you'll see direct sign-in links. If not, we'll explain your next options.
            </p>
          </div>
        </li>
      </ol>
    </div>

    <div class="pt-6 border-t border-[var(--border)] text-center">
      <p class="text-xs text-[var(--text-tertiary)]">
        Wrong address? <.link href={~p"/find_account"} class={[link_style()]}>Try again.</.link>
      </p>
    </div>
    """
  end

  # ── Event handlers ────────────────────────────────────────────────────────────

  def handle_event("validate_email", %{"email_form" => attrs}, socket) do
    changeset = EmailForm.changeset(attrs) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :email_form))}
  end

  def handle_event("submit_email", %{"email_form" => attrs}, socket) do
    changeset = EmailForm.changeset(attrs) |> Map.put(:action, :insert)

    if changeset.valid? do
      email = Ecto.Changeset.get_field(changeset, :email)
      accounts = Database.find_accounts_by_actor_email(email)

      rate_limit_opts = [
        rate_limit_key: {:find_account, String.downcase(email)},
        rate_limit: 3,
        rate_limit_interval: :timer.minutes(30)
      ]

      if accounts != [] do
        accounts_with_urls = Enum.map(accounts, &{&1, url(~p"/#{&1.slug}/sign_in")})

        Portal.Mailer.AuthEmail.existing_accounts_email(email, accounts_with_urls)
        |> Portal.Mailer.deliver_with_rate_limit(rate_limit_opts)
      else
        Portal.Mailer.AuthEmail.no_accounts_found_email(email, url(~p"/sign_up"))
        |> Portal.Mailer.deliver_with_rate_limit(rate_limit_opts)
      end

      {:noreply, assign(socket, step: :email_sent, submitted_email: email)}
    else
      {:noreply, assign(socket, form: to_form(changeset, as: :email_form))}
    end
  end

  # ── Database ──────────────────────────────────────────────────────────────────

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    @spec find_accounts_by_actor_email(String.t()) :: [Portal.Account.t()]
    def find_accounts_by_actor_email(email) do
      from(acc in Portal.Account,
        join: a in Portal.Actor,
        on: a.account_id == acc.id,
        where: a.email == ^email,
        distinct: true
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end
  end
end
