defmodule PortalWeb.SignUp do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias Portal.Config
  alias __MODULE__.Database
  require Logger

  @sign_up_token_salt "sign_up_email_v1"
  @sign_up_token_max_age 86_400

  # ── Full registration schema ──────────────────────────────────────────────────

  defmodule Registration do
    use Ecto.Schema
    @primary_key false
    @foreign_key_type :binary_id
    @timestamps_opts [type: :utc_datetime_usec]

    alias Portal.{Accounts, Actor}

    import Ecto.Changeset
    import Portal.Changeset

    embedded_schema do
      field(:email, :string)
      field(:phone, :string)
      embeds_one(:account, Portal.Account)
      embeds_one(:actor, Actor)
    end

    @spec changeset(map()) :: Ecto.Changeset.t()
    def changeset(attrs) do
      %Registration{}
      |> cast(attrs, [:email, :phone])
      |> validate_required([:email])
      |> trim_change(:email)
      |> trim_change(:phone)
      |> validate_email(:email)
      |> validate_email_allowed()
      |> cast_embed(:account, with: fn _account, a -> create_account_changeset(a) end)
      |> cast_embed(:actor, with: fn _actor, a -> create_actor_changeset(a) end)
    end

    defp validate_email_allowed(changeset) do
      whitelisted_domains = Portal.Config.get_env(:portal, :sign_up_whitelisted_domains)
      do_validate_email_allowed(changeset, whitelisted_domains)
    end

    defp do_validate_email_allowed(changeset, []), do: changeset

    defp do_validate_email_allowed(changeset, whitelisted_domains) do
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

    defp create_account_changeset(attrs) do
      %Portal.Account{}
      |> cast(attrs, [:name, :legal_name, :slug])
      |> Portal.Account.changeset()
      |> put_default_value(:config, %Accounts.Config{})
    end

    defp create_actor_changeset(attrs) do
      %Actor{}
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 255)
    end
  end

  # ── Mount & params ────────────────────────────────────────────────────────────

  def mount(_params, _session, socket) do
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
    real_ip = PortalWeb.Authentication.real_ip(socket)

    case socket.assigns.live_action do
      :verify ->
        {:ok,
         assign(socket,
           page_title: "Verify Sign Up",
           step: :verifying,
           account: nil,
           provider: nil,
           actor: nil,
           error_message: nil,
           user_agent: user_agent,
           real_ip: real_ip
         )}

      _ ->
        sign_up_enabled? = Config.sign_up_enabled?()

        socket =
          assign(socket,
            page_title: "Sign Up",
            step: :fill_form,
            form:
              to_form(Registration.changeset(%{"actor" => %{"type" => "account_admin_user"}}),
                as: :registration
              ),
            account: nil,
            provider: nil,
            actor: nil,
            user_agent: user_agent,
            real_ip: real_ip,
            sign_up_enabled?: sign_up_enabled?
          )

        {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    end
  end

  def handle_params(%{"token" => token}, _uri, %{assigns: %{live_action: :verify}} = socket) do
    if connected?(socket) do
      {:noreply, handle_verified_sign_up_token(socket, token)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :verify}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/sign_up")}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(%{live_action: :verify} = assigns) do
    ~H"""
    <.verifying :if={@step == :verifying} />
    <.sign_up_error :if={@step == :error} error_message={@error_message} />
    <.welcome :if={@step == :account_created} account={@account} provider={@provider} actor={@actor} />
    """
  end

  def render(assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} />
    <.flash flash={@flash} kind={:info} />

    <.sign_up_disabled :if={!@sign_up_enabled?} />
    <.sign_up_form :if={@sign_up_enabled? && @step == :fill_form} form={@form} />
    <.email_sent :if={@sign_up_enabled? && @step == :email_sent} />
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  defp sign_up_form(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center shrink-0">
        <.icon name="ri-building-line" class="w-6 h-6 text-[var(--brand)]" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Create your organization
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          Set up Firezone and become the admin for your team.
        </p>
      </div>
    </div>

    <.form for={@form} phx-submit="submit" phx-change="validate" class="flex flex-col gap-3">
      <.input
        field={@form[:email]}
        type="email"
        label="Work Email"
        placeholder="E.g. foo@example.com"
        required
        autofocus
        phx-debounce="300"
      />

      <.inputs_for :let={account} field={@form[:account]}>
        <.input
          field={account[:name]}
          type="text"
          label="Company Name"
          placeholder="E.g. Example Corp"
          required
          phx-debounce="300"
        />
      </.inputs_for>

      <.inputs_for :let={actor} field={@form[:actor]}>
        <.input
          field={actor[:name]}
          type="text"
          label="Your Name"
          placeholder="E.g. John Smith"
          required
          phx-debounce="300"
        />
        <.input field={actor[:type]} type="hidden" />
      </.inputs_for>

      <div class="absolute -left-[10000px] top-auto w-px h-px overflow-hidden" aria-hidden="true">
        <.input
          field={@form[:phone]}
          type="text"
          label="Phone"
          placeholder="123-456-7890"
          tabindex="-1"
          autocomplete="off"
        />
      </div>

      <button
        type="submit"
        phx-disable-with="Sending..."
        class="w-full py-2.5 rounded text-sm font-semibold bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors mt-1"
      >
        Create Account
      </button>
    </.form>

    <div class="mt-2 pt-2 text-center">
      <p class="text-xs text-[var(--text-tertiary)] mt-1.5">
        By signing up you agree to our <.link
          href="https://www.firezone.dev/terms"
          class={link_style()}
        >Terms of Use</.link>.
      </p>
    </div>

    <div class="mt-12 pt-4 border-t border-[var(--border)] text-center">
      <p class="text-xs text-[var(--text-tertiary)] leading-relaxed">
        Organization already have an account?
        <.link href={~p"/sign_in"} class={[link_style()]}>Sign in here.</.link>
      </p>
      <p class="text-xs text-[var(--text-tertiary)] leading-relaxed">
        Not sure where to start?
        <.link href={~p"/getting_started"} class={[link_style()]}>Let's get started.</.link>
      </p>
    </div>
    """
  end

  defp email_sent(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center shrink-0">
        <.icon name="ri-mail-line" class="w-5 h-5 text-[var(--brand)]" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">Check your email</h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          We've sent a sign-up link to your inbox.
        </p>
      </div>
    </div>

    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-6">
      <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest mb-4">
        What happens next
      </p>
      <ol class="space-y-4">
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center">
            <span class="text-xs font-bold text-[var(--brand)]">1</span>
          </div>
          <div>
            <p class="text-sm font-medium text-[var(--text-primary)]">Open the email from Firezone</p>
            <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
              Check your inbox (and spam folder) for a message with subject "Complete your Firezone sign up".
            </p>
          </div>
        </li>
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center">
            <span class="text-xs font-bold text-[var(--brand)]">2</span>
          </div>
          <div>
            <p class="text-sm font-medium text-[var(--text-primary)]">Click the verification link</p>
            <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
              The link will verify your email and automatically create your organization. It expires in 24 hours.
            </p>
          </div>
        </li>
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center">
            <span class="text-xs font-bold text-[var(--brand)]">3</span>
          </div>
          <div>
            <p class="text-sm font-medium text-[var(--text-primary)]">Sign in and invite your team</p>
            <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
              You'll land in your account, ready to add users and set up access.
            </p>
          </div>
        </li>
      </ol>
    </div>

    <div class="pt-6 border-t border-[var(--border)] text-center">
      <p class="text-xs text-[var(--text-tertiary)]">
        Wrong address or didn't receive it?
        <.link href={~p"/sign_up"} class={[link_style()]}>Start over.</.link>
      </p>
    </div>
    """
  end

  defp welcome(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center shrink-0">
        <.icon name="ri-checkbox-circle-line" class="w-5 h-5 text-[var(--brand)]" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Your account has been created!
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          You're all set. Sign in to get started.
        </p>
      </div>
    </div>

    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-4">
      <dl class="space-y-3">
        <div class="flex justify-between items-baseline">
          <dt class="text-xs font-medium text-[var(--text-secondary)]">Account Name</dt>
          <dd class="text-sm text-[var(--text-primary)]">{@account.name}</dd>
        </div>
        <div class="flex justify-between items-baseline">
          <dt class="text-xs font-medium text-[var(--text-secondary)]">Account Slug</dt>
          <dd class="text-sm text-[var(--text-primary)]">{@account.slug}</dd>
        </div>
        <div class="flex justify-between items-baseline">
          <dt class="text-xs font-medium text-[var(--text-secondary)]">Sign In URL</dt>
          <dd class="text-sm">
            <.link class={[link_style()]} navigate={~p"/#{@account}"}>
              {url(~p"/#{@account}")}
            </.link>
          </dd>
        </div>
      </dl>
    </div>

    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-6">
      <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest mb-3">
        Next Steps
      </p>
      <ul class="space-y-2">
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-[var(--brand)]/10 text-[var(--brand)] rounded-full flex items-center justify-center text-xs font-semibold">
            1
          </span>
          <span class="text-sm text-[var(--text-secondary)]">
            <.website_link path="/kb/client-apps">Download the Firezone Client</.website_link>
            for your platform
          </span>
        </li>
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-[var(--brand)]/10 text-[var(--brand)] rounded-full flex items-center justify-center text-xs font-semibold">
            2
          </span>
          <span class="text-sm text-[var(--text-secondary)]">
            <.website_link path="/kb/quickstart">View the Quickstart Guide</.website_link>
            to get started
          </span>
        </li>
      </ul>
    </div>

    <.form
      for={%{}}
      id="sign-in-form"
      as={:email}
      action={~p"/#{@account}/sign_in/email_otp/#{@provider}"}
      method="post"
    >
      <.input type="hidden" name="email[email]" value={@actor.email} />
      <button
        type="submit"
        class="w-full py-2.5 rounded text-sm font-semibold bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors"
      >
        Sign In
      </button>
    </.form>
    """
  end

  defp sign_up_disabled(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-rose-50 dark:bg-rose-950/30 border border-rose-200 dark:border-rose-800 flex items-center justify-center shrink-0">
        <.icon name="ri-prohibited-line" class="w-5 h-5 text-rose-500" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Sign-ups are currently disabled
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          Contact us to get access.
        </p>
      </div>
    </div>

    <div class="pt-6 border-t border-[var(--border)] text-center">
      <p class="text-xs text-[var(--text-tertiary)] leading-relaxed">
        Please contact
        <a class={link_style()} href="mailto:sales@firezone.dev?subject=Firezone Sign Up Request">
          sales@firezone.dev
        </a>
        for more information.
      </p>
    </div>
    """
  end

  defp verifying(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center shrink-0">
        <.icon name="ri-loader-4-line" class="w-5 h-5 text-[var(--brand)] animate-spin" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Verifying your sign-up link&hellip;
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          This will only take a moment.
        </p>
      </div>
    </div>

    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-6">
      <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest mb-3">
        What's happening
      </p>
      <ol class="space-y-3">
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-[var(--brand)]/10 text-[var(--brand)] rounded-full flex items-center justify-center text-xs font-semibold">
            1
          </span>
          <span class="text-sm text-[var(--text-secondary)]">Verifying your sign-up link</span>
        </li>
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-[var(--surface-sunken)] text-[var(--text-muted)] rounded-full flex items-center justify-center text-xs font-semibold">
            2
          </span>
          <span class="text-sm text-[var(--text-muted)]">Creating your account</span>
        </li>
      </ol>
    </div>
    """
  end

  defp sign_up_error(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class="w-11 h-11 rounded bg-rose-50 dark:bg-rose-950/30 border border-rose-200 dark:border-rose-800 flex items-center justify-center shrink-0">
        <.icon name="ri-error-warning-line" class="w-5 h-5 text-rose-500" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Something went wrong
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          We weren't able to complete your sign up.
        </p>
      </div>
    </div>

    <div class="rounded border border-rose-200 dark:border-rose-800 bg-rose-50 dark:bg-rose-950/30 p-4 mb-6">
      <p class="text-sm text-rose-700 dark:text-rose-400">{@error_message}</p>
    </div>

    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-6">
      <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest mb-3">
        What you can do
      </p>
      <ul class="space-y-2">
        <li class="flex items-start gap-2.5">
          <.icon
            name="ri-arrow-right-s-line"
            class="w-3.5 h-3.5 mt-0.5 shrink-0 text-[var(--text-tertiary)]"
          />
          <span class="text-sm text-[var(--text-secondary)]">
            Try signing up again — your verification link may have expired.
          </span>
        </li>
        <li class="flex items-start gap-2.5">
          <.icon
            name="ri-arrow-right-s-line"
            class="w-3.5 h-3.5 mt-0.5 shrink-0 text-[var(--text-tertiary)]"
          />
          <span class="text-sm text-[var(--text-secondary)]">
            If you already have an account,
            <.link href={~p"/"} class={link_style()}>sign in here.</.link>
          </span>
        </li>
        <li class="flex items-start gap-2.5">
          <.icon
            name="ri-arrow-right-s-line"
            class="w-3.5 h-3.5 mt-0.5 shrink-0 text-[var(--text-tertiary)]"
          />
          <span class="text-sm text-[var(--text-secondary)]">
            Still having trouble?
            <a class={link_style()} href="mailto:support@firezone.dev">Contact support.</a>
          </span>
        </li>
      </ul>
    </div>

    <.link
      href={~p"/sign_up"}
      class="block w-full py-2.5 rounded text-sm font-semibold text-center bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors"
    >
      Try again
    </.link>
    """
  end

  # ── Event handlers ────────────────────────────────────────────────────────────

  def handle_event("validate", %{"registration" => attrs}, socket) do
    attrs = normalize_registration_attrs(attrs)

    changeset = Registration.changeset(attrs) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :registration))}
  end

  def handle_event("submit", %{"registration" => attrs}, socket) do
    attrs = normalize_registration_attrs(attrs)

    if honeypot_filled?(attrs) do
      log_honeypot_hit(attrs, socket.assigns.user_agent, socket.assigns.real_ip)
      {:noreply, assign(socket, step: :email_sent)}
    else
      changeset = Registration.changeset(attrs) |> Map.put(:action, :insert)
      {:noreply, apply_registration(socket, changeset)}
    end
  end

  defp apply_registration(socket, %{valid?: true} = changeset)
       when socket.assigns.sign_up_enabled? do
    registration = Ecto.Changeset.apply_changes(changeset)
    existing_accounts = Database.find_accounts_by_owner_email(registration.email)

    result =
      if existing_accounts == [] do
        send_verification_email(
          registration.email,
          registration.account.name,
          registration.actor.name
        )
      else
        send_existing_accounts_email(registration.email, existing_accounts)
      end

    case result do
      {:ok, _} ->
        assign(socket, step: :email_sent)

      {:error, :rate_limited} ->
        new_changeset =
          Ecto.Changeset.add_error(changeset, :email, "Too many attempts. Please try again later.")

        assign(socket, form: to_form(new_changeset, as: :registration))

      {:error, _reason} ->
        new_changeset =
          Ecto.Changeset.add_error(
            changeset,
            :email,
            "We were unable to send you an email. Please try again later."
          )

        assign(socket, form: to_form(new_changeset, as: :registration))
    end
  end

  defp apply_registration(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :registration))
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp normalize_registration_attrs(attrs) do
    attrs
    |> Map.update(
      "actor",
      %{"type" => "account_admin_user"},
      &Map.put(&1, "type", "account_admin_user")
    )
    |> Map.update("phone", "", &String.trim/1)
  end

  defp honeypot_filled?(attrs), do: Map.get(attrs, "phone", "") != ""

  defp log_honeypot_hit(attrs, user_agent, real_ip) do
    Logger.warning("Sign-up honeypot triggered",
      email: normalize_log_value(Map.get(attrs, "email")),
      user_agent: normalize_log_value(user_agent),
      real_ip: inspect(real_ip)
    )
  end

  defp normalize_log_value(nil), do: nil
  defp normalize_log_value(value) when is_binary(value), do: String.trim(value)

  @spec send_existing_accounts_email(String.t(), [Portal.Account.t()]) ::
          {:ok, any()} | {:error, any()}
  defp send_existing_accounts_email(email, accounts) do
    accounts_with_urls = Enum.map(accounts, fn account -> {account, url(~p"/#{account}")} end)

    Portal.Mailer.AuthEmail.sign_up_account_exists_email(email, accounts_with_urls)
    |> Portal.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:sign_up_verification, String.downcase(email)},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(30)
    )
  end

  @spec send_verification_email(String.t(), String.t(), String.t()) ::
          {:ok, any()} | {:error, any()}
  defp send_verification_email(email, company_name, actor_name) do
    payload = %{email: email, company_name: company_name, actor_name: actor_name}
    token = Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, payload)
    sign_up_url = url(~p"/verify_sign_up?token=#{token}")

    Portal.Mailer.AuthEmail.sign_up_verification_email(email, sign_up_url)
    |> Portal.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:sign_up_verification, String.downcase(email)},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(30)
    )
  end

  defp create_account_changeset(attrs) do
    import Ecto.Changeset

    %Portal.Account{id: Map.get(attrs, :id)}
    |> cast(attrs, [:name, :legal_name, :slug, :key])
    |> maybe_default_legal_name()
    |> maybe_generate_slug()
    |> put_change(:key, Portal.Account.new_key())
    |> put_default_config()
    |> cast_embed(:metadata)
    |> validate_required([:name, :legal_name, :slug, :key])
    |> Portal.Account.changeset()
  end

  defp put_default_config(changeset) do
    import Ecto.Changeset
    default_config = Portal.Accounts.Config.default_config()
    put_change(changeset, :config, default_config)
  end

  defp maybe_generate_slug(changeset) do
    import Ecto.Changeset

    case get_field(changeset, :slug) do
      nil ->
        put_change(changeset, :slug, generate_unique_slug())

      "placeholder" ->
        put_change(changeset, :slug, generate_unique_slug())

      _ ->
        changeset
    end
  end

  defp generate_unique_slug do
    slug_candidate = Portal.NameGenerator.generate_slug()

    if Database.slug_exists?(slug_candidate) do
      generate_unique_slug()
    else
      slug_candidate
    end
  end

  defp maybe_default_legal_name(changeset) do
    import Ecto.Changeset

    case get_field(changeset, :legal_name) do
      nil ->
        name = get_field(changeset, :name)
        put_change(changeset, :legal_name, name)

      _ ->
        changeset
    end
  end

  defp create_everyone_group_changeset(account) do
    import Ecto.Changeset

    %Portal.Group{}
    |> cast(%{name: "Everyone"}, [:name])
    |> put_change(:account_id, account.id)
    |> put_change(:type, :managed)
    |> validate_required([:name, :account_id, :type])
  end

  defp register_account(registration, user_agent, real_ip) do
    account_id = Ecto.UUID.generate()

    case Portal.Billing.provision_stripe_for_signup(
           account_id,
           registration.account.name,
           registration.email
         ) do
      {:ok, stripe_info} ->
        changeset_fns = %{
          account: &create_account_changeset/1,
          everyone_group: &create_everyone_group_changeset/1,
          site: &create_site_changeset/2,
          internet_site: &create_internet_site_changeset/1,
          internet_resource: &create_internet_resource_changeset/2
        }

        Database.register_account(
          registration,
          account_id,
          stripe_info,
          changeset_fns,
          user_agent,
          real_ip
        )

      {:error, _reason} ->
        {:error, :stripe_provision}
    end
  end

  defp handle_verified_sign_up_token(socket, token) do
    case verify_sign_up_token(token) do
      {:ok, registration_claims} ->
        complete_verified_sign_up(
          socket,
          registration_claims,
          socket.assigns.user_agent,
          socket.assigns.real_ip
        )

      {:error, message} ->
        sign_up_error(socket, message)
    end
  end

  defp verify_sign_up_token(token) do
    case Phoenix.Token.verify(PortalWeb.Endpoint, @sign_up_token_salt, token,
           max_age: @sign_up_token_max_age
         ) do
      {:ok, registration_claims} ->
        {:ok, registration_claims}

      {:error, _} ->
        {:error, "This sign-up link is invalid or has expired."}
    end
  end

  defp complete_verified_sign_up(
         socket,
         %{
           email: email,
           company_name: company_name,
           actor_name: actor_name
         },
         user_agent,
         real_ip
       ) do
    case Database.find_account_by_owner_email(email) do
      %Portal.Account{} = account ->
        push_navigate(socket, to: ~p"/#{account}/sign_in")

      nil ->
        registration = %{
          email: email,
          account: %{name: company_name},
          actor: %{name: actor_name}
        }

        handle_registration_result(socket, register_account(registration, user_agent, real_ip))
    end
  end

  defp handle_registration_result(
         socket,
         {:ok, %{account: account, provider: provider, actor: actor}}
       ) do
    assign(socket,
      step: :account_created,
      account: account,
      provider: provider,
      actor: actor
    )
  end

  defp handle_registration_result(socket, {:error, :stripe_provision}) do
    sign_up_error(socket, "We encountered a temporary error. Please try again.")
  end

  defp handle_registration_result(socket, {:error, _, _, _}) do
    sign_up_error(socket, "We encountered an error creating your account. Please try again.")
  end

  defp sign_up_error(socket, message) do
    assign(socket, step: :error, error_message: message)
  end

  defp create_site_changeset(account, attrs) do
    import Ecto.Changeset

    %Portal.Site{
      account_id: account.id,
      managed_by: :account,
      gateway_tokens: []
    }
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Portal.Site.changeset()
  end

  defp create_internet_site_changeset(account) do
    import Ecto.Changeset

    %Portal.Site{
      account_id: account.id,
      managed_by: :system,
      gateway_tokens: []
    }
    |> cast(%{name: "Internet", managed_by: :system}, [:name, :managed_by])
    |> validate_required([:name, :managed_by])
    |> Portal.Site.changeset()
  end

  defp create_internet_resource_changeset(account, site) do
    import Ecto.Changeset

    attrs = %{type: :internet, name: "Internet"}

    %Portal.Resource{account_id: account.id, site_id: site.id}
    |> cast(attrs, [:type, :name])
    |> validate_required([:name, :type])
  end

  # ── Database ─────────────────────────────────────────────────────────────────

  defmodule Database do
    import Ecto.Changeset
    import Ecto.Query

    alias Portal.{
      Actor,
      AuthProvider,
      EmailOTP,
      Safe
    }

    @spec find_account_by_owner_email(String.t()) :: Portal.Account.t() | nil
    def find_account_by_owner_email(email) do
      from(a in Portal.Account,
        where:
          fragment("?->'stripe'->>'billing_email' = ?", a.metadata, ^email) and
            fragment(
              "(?->'stripe'->>'product_name' IS NULL OR ?->'stripe'->>'product_name' = 'Starter')",
              a.metadata,
              a.metadata
            ),
        order_by: [desc: a.inserted_at],
        limit: 1
      )
      |> Safe.unscoped(:replica)
      |> Safe.one()
    end

    @spec find_accounts_by_owner_email(String.t()) :: [Portal.Account.t()]
    def find_accounts_by_owner_email(email) do
      from(a in Portal.Account,
        where:
          fragment("?->'stripe'->>'billing_email' = ?", a.metadata, ^email) and
            fragment(
              "(?->'stripe'->>'product_name' IS NULL OR ?->'stripe'->>'product_name' = 'Starter')",
              a.metadata,
              a.metadata
            ),
        order_by: [asc: a.inserted_at]
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    @spec slug_exists?(String.t()) :: boolean()
    def slug_exists?(slug) do
      from(a in Portal.Account, where: a.slug == ^slug)
      |> Safe.unscoped(:replica)
      |> Safe.exists?()
    end

    # OTP 28 dialyzer is stricter about opaque types (MapSet) inside Ecto.Multi
    @dialyzer {:no_opaque, [register_account: 6, create_email_provider: 1]}
    @spec register_account(any(), String.t(), any(), map(), any(), any()) ::
            {:ok, map()} | {:error, atom(), any(), map()}
    def register_account(
          registration,
          account_id,
          stripe_info,
          changeset_fns,
          user_agent,
          real_ip
        ) do
      stripe_metadata = stripe_info || %{billing_email: registration.email}

      Ecto.Multi.new()
      |> Ecto.Multi.run(:account, fn _repo, _changes ->
        attrs = %{
          id: account_id,
          name: registration.account.name,
          metadata: %{stripe: stripe_metadata}
        }

        insert_account_with_key_retry(attrs, changeset_fns.account)
      end)
      |> Ecto.Multi.run(:everyone_group, fn _repo, %{account: account} ->
        changeset_fns.everyone_group.(account)
        |> insert()
      end)
      |> Ecto.Multi.run(:provider, fn _repo, %{account: account} ->
        create_email_provider(account)
      end)
      |> Ecto.Multi.run(:actor, fn _repo, %{account: account} ->
        create_admin(account, registration.email, registration.actor.name)
      end)
      |> Ecto.Multi.run(:default_site, fn _repo, %{account: account} ->
        changeset_fns.site.(account, %{name: "Default Site"})
        |> insert()
      end)
      |> Ecto.Multi.run(:internet_site, fn _repo, %{account: account} ->
        changeset_fns.internet_site.(account)
        |> insert()
      end)
      |> Ecto.Multi.run(:internet_resource, fn _repo,
                                               %{account: account, internet_site: internet_site} ->
        changeset_fns.internet_resource.(account, internet_site)
        |> insert()
      end)
      |> Ecto.Multi.run(:send_email, fn _repo, %{account: account, actor: actor} ->
        Portal.Mailer.AuthEmail.sign_up_link_email(account, actor, user_agent, real_ip)
        |> Portal.Mailer.deliver_with_rate_limit(
          rate_limit_key: {:sign_up_link, String.downcase(actor.email)},
          rate_limit: 3,
          rate_limit_interval: :timer.minutes(30)
        )
      end)
      |> Safe.transact()
    end

    @spec create_email_provider(Portal.Account.t()) ::
            {:ok, Portal.EmailOTP.AuthProvider.t()} | {:error, Ecto.Changeset.t()}
    def create_email_provider(account) do
      id = Ecto.UUID.generate()

      parent_changeset =
        cast(
          %AuthProvider{},
          %{account_id: account.id, id: id, type: :email_otp},
          ~w[id account_id type]a
        )

      email_otp_changeset =
        cast(
          %EmailOTP.AuthProvider{},
          %{id: id, account_id: account.id, name: "Email (OTP)"},
          ~w[id account_id name]a
        )
        |> EmailOTP.AuthProvider.changeset()

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:auth_provider, parent_changeset)
      |> Ecto.Multi.insert(:email_otp_provider, email_otp_changeset)
      |> Safe.transact()
      |> case do
        {:ok, %{email_otp_provider: email_provider}} -> {:ok, email_provider}
        {:error, _step, changeset, _changes} -> {:error, changeset}
      end
    end

    @spec create_admin(Portal.Account.t(), String.t(), String.t()) ::
            {:ok, Portal.Actor.t()} | {:error, Ecto.Changeset.t()}
    def create_admin(account, email, name) do
      attrs = %{
        account_id: account.id,
        email: email,
        name: name,
        type: :account_admin_user,
        allow_email_otp_sign_in: true
      }

      cast(%Portal.Actor{}, attrs, ~w[account_id email name type allow_email_otp_sign_in]a)
      |> Portal.Actor.changeset()
      |> Safe.unscoped()
      |> Safe.insert()
    end

    @spec insert(Ecto.Changeset.t()) :: {:ok, any()} | {:error, Ecto.Changeset.t()}
    def insert(changeset) do
      Safe.unscoped(changeset)
      |> Safe.insert()
    end

    def insert_account_with_key_retry(attrs, changeset_fn, retries \\ 5) do
      changeset_fn.(attrs)
      |> Safe.unscoped()
      |> Safe.insert()
      |> case do
        {:ok, account} ->
          {:ok, account}

        {:error, %Ecto.Changeset{} = changeset} ->
          if retries > 0 and key_taken?(changeset) do
            insert_account_with_key_retry(attrs, changeset_fn, retries - 1)
          else
            {:error, changeset}
          end
      end
    end

    defp key_taken?(%Ecto.Changeset{errors: errors}) do
      Keyword.has_key?(errors, :key) and
        match?({"has already been taken", _}, Keyword.get(errors, :key))
    end
  end
end
