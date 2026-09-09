defmodule PortalWeb.SignUp do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database
  require Logger

  @sign_up_token_salt "sign_up_email_v1"
  @sign_up_token_max_age 86_400
  @google_sign_up_session_key "google_sign_up"
  @google_sign_up_max_age 900
  @email_domain_error "This email domain is not allowed at this time."
  @google_session_error "Your Google sign-up session is invalid or has expired. Please try again."

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

  def mount(_params, session, socket) do
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
    real_ip = PortalWeb.Authentication.real_ip(socket)
    website_attribution = PortalWeb.WebsiteAttribution.fetch(session)

    case socket.assigns.live_action do
      :verify ->
        {:ok,
         assign(socket,
           page_title: "Verify Sign Up",
           step: :verifying,
           account: nil,
           provider: nil,
           google_provider: nil,
           actor: nil,
           error_message: nil,
           website_attribution: website_attribution,
           user_agent: user_agent,
           real_ip: real_ip
         )}

      _ ->
        socket =
          assign(socket,
            page_title: "Sign Up",
            step: :choose,
            form: registration_form(%{}),
            account: nil,
            provider: nil,
            google_provider: nil,
            actor: nil,
            error_message: nil,
            google_identity: identity_from_session(session),
            existing_accounts: [],
            website_attribution: website_attribution,
            user_agent: user_agent,
            real_ip: real_ip
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

  def handle_params(_params, _uri, %{assigns: %{live_action: :google}} = socket) do
    identity = socket.assigns.google_identity

    if is_nil(identity) or identity_expired?(identity) do
      {:noreply, sign_up_error(socket, @google_session_error)}
    else
      {:noreply, start_google_sign_up(socket, identity)}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :fill_form}} = socket) do
    {:noreply, assign(socket, step: :fill_form, form: registration_form(%{}))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, step: :choose)}

  # ── Google identity session ──────────────────────────────────────────────────

  def session_key, do: @google_sign_up_session_key

  # Only what registration needs; the picture URL alone can be 2 KB and the
  # first Google sign-in fills the rest in through the identity upsert.
  @spec session_identity(PortalWeb.OIDC.IdentityProfile.t()) :: map()
  def session_identity(%PortalWeb.OIDC.IdentityProfile{} = profile) do
    %{
      "email" => profile.email,
      "issuer" => profile.issuer,
      "idp_id" => profile.idp_id,
      "name" => profile.profile_attrs["name"],
      "given_name" => profile.profile_attrs["given_name"],
      "family_name" => profile.profile_attrs["family_name"],
      "expires_at" => System.os_time(:second) + @google_sign_up_max_age
    }
  end

  defp identity_from_session(session) do
    case Map.get(session, @google_sign_up_session_key) do
      %{
        "email" => email,
        "issuer" => issuer,
        "idp_id" => idp_id,
        "expires_at" => expires_at
      } = identity
      when is_binary(email) and is_binary(issuer) and is_binary(idp_id) and
             is_integer(expires_at) ->
        identity = %{
          email: email,
          issuer: issuer,
          idp_id: idp_id,
          expires_at: expires_at,
          profile_attrs: Map.take(identity, ~w[email name given_name family_name])
        }

        if identity_expired?(identity) do
          nil
        else
          identity
        end

      _ ->
        nil
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(%{live_action: :verify} = assigns) do
    ~H"""
    <.verifying :if={@step == :verifying} />
    <.sign_up_error :if={@step == :error} error_message={@error_message} />
    <.welcome
      :if={@step == :account_created}
      account={@account}
      provider={@provider}
      google_provider={@google_provider}
      actor={@actor}
    />
    """
  end

  def render(assigns) do
    ~H"""
    <.flash flash={@flash} kind={:error} />
    <.flash flash={@flash} kind={:info} />

    <.method_chooser :if={@step == :choose} />
    <.sign_up_form :if={@step == :fill_form} form={@form} />
    <.google_sign_up_form
      :if={@step == :google_form}
      form={@form}
      email={@google_identity.email}
    />
    <.existing_accounts :if={@step == :existing_accounts} accounts={@existing_accounts} />
    <.email_sent :if={@step == :email_sent} />
    <.sign_up_error :if={@step == :error} error_message={@error_message} />
    <.welcome
      :if={@step == :account_created}
      account={@account}
      provider={@provider}
      google_provider={@google_provider}
      actor={@actor}
    />
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  defp sign_up_form(assigns) do
    ~H"""
    <.step_header title="Create your organization" subtitle="Set up Firezone and become the admin for your team.">
      <:icon><.icon name="ri-building-line" class="w-6 h-6 text-brand" /></:icon>
    </.step_header>

    <.form id="sign-up-form" for={@form} phx-submit="submit" phx-change="validate" class="flex flex-col gap-3">
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
        class="w-full py-2.5 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors mt-1"
      >
        Create Account
      </button>
    </.form>

    <.terms_notice />

    <.footer>
      <p class="text-xs text-subtle leading-relaxed">
        Prefer to use Google?
        <.link patch={~p"/sign_up"} class={[link_style()]}>Sign up with Google.</.link>
      </p>
      <.sign_in_links />
    </.footer>
    """
  end

  defp method_chooser(assigns) do
    ~H"""
    <.step_header title="Create your organization" subtitle="Set up Firezone and become the admin for your team.">
      <:icon><.icon name="ri-building-line" class="w-6 h-6 text-brand" /></:icon>
    </.step_header>

    <div class="flex flex-col gap-2">
      <.form for={%{}} id="google-sign-up" action={~p"/sign_up/google"} method="post">
        <button type="submit" class={method_button_style()}>
          <.provider_icon provider="google" size="md" />
          <span class="flex-1 text-left">Sign up with <strong>Google</strong></span>
          <.icon name="ri-arrow-right-s-line" class={method_button_arrow_style()} />
        </button>
      </.form>

      <.link patch={~p"/sign_up/email"} class={method_button_style()}>
        <span class="shrink-0 w-6 h-6 flex items-center justify-center">
          <.icon name="ri-mail-line" class="w-5 h-5 text-brand" />
        </span>
        <span class="flex-1 text-left">Sign up with <strong>email</strong></span>
        <.icon name="ri-arrow-right-s-line" class={method_button_arrow_style()} />
      </.link>
    </div>

    <.terms_notice />

    <.footer>
      <.sign_in_links />
    </.footer>
    """
  end

  attr :form, :any, required: true
  attr :email, :string, required: true

  defp google_sign_up_form(assigns) do
    ~H"""
    <.step_header title="Almost there" subtitle="Tell us about your organization to finish signing up.">
      <:icon><.provider_icon provider="google" size="md" /></:icon>
    </.step_header>

    <.form
      id="google-sign-up-form"
      for={@form}
      phx-submit="submit_google"
      phx-change="validate"
      class="flex flex-col gap-3"
    >
      <div>
        <label class="block text-sm font-medium text-heading mb-1">Work Email</label>
        <div class="w-full px-3 py-2 text-sm rounded border bg-raised border-border text-body flex items-center gap-2">
          <.icon name="ri-checkbox-circle-line" class="w-4 h-4 text-brand shrink-0" />
          <span class="truncate">{@email}</span>
          <span class="ml-auto text-xs text-subtle shrink-0">Verified by Google</span>
        </div>
      </div>

      <.inputs_for :let={account} field={@form[:account]}>
        <.input
          field={account[:name]}
          type="text"
          label="Company Name"
          placeholder="E.g. Example Corp"
          required
          autofocus
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
      </.inputs_for>

      <button
        type="submit"
        phx-disable-with="Creating..."
        class="w-full py-2.5 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors mt-1"
      >
        Create Account
      </button>
    </.form>

    <.terms_notice />

    <.footer>
      <p class="text-xs text-subtle leading-relaxed">
        Wrong Google account?
        <.link href={~p"/sign_up"} class={[link_style()]}>Start over.</.link>
      </p>
    </.footer>
    """
  end

  attr :accounts, :list, required: true

  defp existing_accounts(assigns) do
    ~H"""
    <.step_header title="You already have an account" subtitle="Your Google email is the owner of the organizations below. Sign in to continue.">
      <:icon><.icon name="ri-building-line" class="w-6 h-6 text-brand" /></:icon>
    </.step_header>

    <div class="flex flex-col gap-2">
      <.link :for={account <- @accounts} href={~p"/#{account}/sign_in"} class={method_button_style()}>
        <span class="flex-1 text-left truncate">{account.name}</span>
        <.icon name="ri-arrow-right-s-line" class={method_button_arrow_style()} />
      </.link>
    </div>

    <.footer>
      <p class="text-xs text-subtle leading-relaxed">
        Want a separate organization?
        <.link patch={~p"/sign_up/email"} class={[link_style()]}>Sign up with a different email.</.link>
      </p>
    </.footer>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :variant, :string, default: "brand", values: ~w[brand error]
  slot :icon, required: true

  defp step_header(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-8">
      <div class={[
        "w-11 h-11 rounded border flex items-center justify-center shrink-0",
        step_header_variant(@variant)
      ]}>
        {render_slot(@icon)}
      </div>
      <div>
        <h1 class="text-xl font-bold text-heading tracking-tight">{@title}</h1>
        <p class="text-xs text-subtle mt-0.5">{@subtitle}</p>
      </div>
    </div>
    """
  end

  defp step_header_variant("brand"), do: "bg-brand/10 border-brand/20"

  defp step_header_variant("error"),
    do: "bg-rose-50 dark:bg-rose-950/30 border-rose-200 dark:border-rose-800"

  defp terms_notice(assigns) do
    ~H"""
    <div class="mt-2 pt-2 text-center">
      <p class="text-xs text-subtle mt-1.5">
        By signing up you agree to our <.link
          href="https://www.firezone.dev/terms"
          class={link_style()}
        >Terms of Use</.link>.
      </p>
    </div>
    """
  end

  slot :inner_block, required: true

  defp footer(assigns) do
    ~H"""
    <div class="mt-12 pt-4 border-t border-border text-center">
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp sign_in_links(assigns) do
    ~H"""
    <p class="text-xs text-subtle leading-relaxed">
      Organization already have an account?
      <.link href={~p"/sign_in"} class={[link_style()]}>Sign in here.</.link>
    </p>
    <p class="text-xs text-subtle leading-relaxed">
      Not sure where to start?
      <.link href={~p"/getting_started"} class={[link_style()]}>Let's get started.</.link>
    </p>
    """
  end

  defp method_button_style do
    "w-full flex items-center gap-3 px-4 py-3 rounded border-2 border-border bg-surface hover:border-brand hover:shadow-sm transition-all duration-150 group text-sm font-medium text-heading"
  end

  defp method_button_arrow_style do
    "w-5 h-5 text-muted group-hover:text-brand group-hover:translate-x-0.5 transition-all shrink-0"
  end

  defp email_sent(assigns) do
    ~H"""
    <.step_header title="Check your email" subtitle="We've sent a sign-up link to your inbox.">
      <:icon><.icon name="ri-mail-line" class="w-5 h-5 text-brand" /></:icon>
    </.step_header>

    <div class="rounded border border-border bg-raised p-4 mb-6">
      <p class="text-xs font-semibold text-body uppercase tracking-widest mb-4">
        What happens next
      </p>
      <ol class="space-y-4">
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-brand/10 border border-brand/20 flex items-center justify-center">
            <span class="text-xs font-bold text-brand">1</span>
          </div>
          <div>
            <p class="text-sm font-medium text-heading">Open the email from Firezone</p>
            <p class="text-xs text-subtle mt-0.5 leading-relaxed">
              Check your inbox (and spam folder) for a message with subject "Complete your Firezone sign up".
            </p>
          </div>
        </li>
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-brand/10 border border-brand/20 flex items-center justify-center">
            <span class="text-xs font-bold text-brand">2</span>
          </div>
          <div>
            <p class="text-sm font-medium text-heading">Click the verification link</p>
            <p class="text-xs text-subtle mt-0.5 leading-relaxed">
              The link will verify your email and automatically create your organization. It expires in 24 hours.
            </p>
          </div>
        </li>
        <li class="flex gap-3">
          <div class="shrink-0 w-6 h-6 rounded-full bg-brand/10 border border-brand/20 flex items-center justify-center">
            <span class="text-xs font-bold text-brand">3</span>
          </div>
          <div>
            <p class="text-sm font-medium text-heading">Sign in and invite your team</p>
            <p class="text-xs text-subtle mt-0.5 leading-relaxed">
              You'll land in your account, ready to add users and set up access.
            </p>
          </div>
        </li>
      </ol>
    </div>

    <div class="pt-6 border-t border-border text-center">
      <p class="text-xs text-subtle">
        Wrong address or didn't receive it?
        <.link href={~p"/sign_up"} class={[link_style()]}>Start over.</.link>
      </p>
    </div>
    """
  end

  defp welcome(assigns) do
    ~H"""
    <.step_header title="Your account has been created!" subtitle="You're all set. Sign in to get started.">
      <:icon><.icon name="ri-checkbox-circle-line" class="w-5 h-5 text-brand" /></:icon>
    </.step_header>

    <div class="rounded border border-border bg-raised p-4 mb-4">
      <dl class="space-y-3">
        <div class="flex justify-between items-baseline">
          <dt class="text-xs font-medium text-body">Account Name</dt>
          <dd class="text-sm text-heading">{@account.name}</dd>
        </div>
        <div class="flex justify-between items-baseline">
          <dt class="text-xs font-medium text-body">Account Slug</dt>
          <dd class="text-sm text-heading">{@account.slug}</dd>
        </div>
        <div class="flex justify-between items-baseline">
          <dt class="text-xs font-medium text-body">Sign In URL</dt>
          <dd class="text-sm">
            <.link class={[link_style()]} href={~p"/#{@account}"}>
              {url(~p"/#{@account}")}
            </.link>
          </dd>
        </div>
      </dl>
    </div>

    <div class="rounded border border-border bg-raised p-4 mb-6">
      <p class="text-xs font-semibold text-body uppercase tracking-widest mb-3">
        Next Steps
      </p>
      <ul class="space-y-2">
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-brand/10 text-brand rounded-full flex items-center justify-center text-xs font-semibold">
            1
          </span>
          <span class="text-sm text-body">
            <.website_link path="/kb/client-apps">Download the Firezone Client</.website_link>
            for your platform
          </span>
        </li>
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-brand/10 text-brand rounded-full flex items-center justify-center text-xs font-semibold">
            2
          </span>
          <span class="text-sm text-body">
            <.website_link path="/kb/quickstart">View the Quickstart Guide</.website_link>
            to get started
          </span>
        </li>
      </ul>
    </div>

    <.link
      :if={@google_provider}
      href={~p"/#{@account}/sign_in/google/#{@google_provider.id}"}
      class="block w-full py-2.5 rounded text-sm font-semibold text-center bg-brand text-white hover:bg-brand-dark transition-colors"
    >
      Sign In with Google
    </.link>

    <.form
      :if={is_nil(@google_provider)}
      for={%{}}
      id="sign-in-form"
      as={:email}
      action={~p"/#{@account}/sign_in/email_otp/#{@provider}"}
      method="post"
    >
      <.input type="hidden" name="email[email]" value={@actor.email} />
      <button
        type="submit"
        class="w-full py-2.5 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors"
      >
        Sign In
      </button>
    </.form>
    """
  end

  defp verifying(assigns) do
    ~H"""
    <.step_header title="Verifying your sign-up link…" subtitle="This will only take a moment.">
      <:icon><.icon name="ri-loader-4-line" class="w-5 h-5 text-brand animate-spin" /></:icon>
    </.step_header>

    <div class="rounded border border-border bg-raised p-4 mb-6">
      <p class="text-xs font-semibold text-body uppercase tracking-widest mb-3">
        What's happening
      </p>
      <ol class="space-y-3">
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-brand/10 text-brand rounded-full flex items-center justify-center text-xs font-semibold">
            1
          </span>
          <span class="text-sm text-body">Verifying your sign-up link</span>
        </li>
        <li class="flex items-center gap-3">
          <span class="shrink-0 w-5 h-5 bg-page text-muted rounded-full flex items-center justify-center text-xs font-semibold">
            2
          </span>
          <span class="text-sm text-muted">Creating your account</span>
        </li>
      </ol>
    </div>
    """
  end

  defp sign_up_error(assigns) do
    ~H"""
    <.step_header title="Something went wrong" subtitle="We weren't able to complete your sign up." variant="error">
      <:icon><.icon name="ri-error-warning-line" class="w-5 h-5 text-rose-500" /></:icon>
    </.step_header>

    <div class="rounded border border-rose-200 dark:border-rose-800 bg-rose-50 dark:bg-rose-950/30 p-4 mb-6">
      <p class="text-sm text-rose-700 dark:text-rose-400">{@error_message}</p>
    </div>

    <div class="rounded border border-border bg-raised p-4 mb-6">
      <p class="text-xs font-semibold text-body uppercase tracking-widest mb-3">
        What you can do
      </p>
      <ul class="space-y-2">
        <li class="flex items-start gap-2.5">
          <.icon
            name="ri-arrow-right-s-line"
            class="w-3.5 h-3.5 mt-0.5 shrink-0 text-subtle"
          />
          <span class="text-sm text-body">
            Try signing up again — your verification link may have expired.
          </span>
        </li>
        <li class="flex items-start gap-2.5">
          <.icon
            name="ri-arrow-right-s-line"
            class="w-3.5 h-3.5 mt-0.5 shrink-0 text-subtle"
          />
          <span class="text-sm text-body">
            If you already have an account,
            <.link href={~p"/"} class={link_style()}>sign in here.</.link>
          </span>
        </li>
        <li class="flex items-start gap-2.5">
          <.icon
            name="ri-arrow-right-s-line"
            class="w-3.5 h-3.5 mt-0.5 shrink-0 text-subtle"
          />
          <span class="text-sm text-body">
            Still having trouble?
            <a class={link_style()} href="mailto:support@firezone.dev">Contact support.</a>
          </span>
        </li>
      </ul>
    </div>

    <.link
      href={~p"/sign_up"}
      class="block w-full py-2.5 rounded text-sm font-semibold text-center bg-brand text-white hover:bg-brand-dark transition-colors"
    >
      Try again
    </.link>
    """
  end

  # ── Event handlers ────────────────────────────────────────────────────────────

  def handle_event("validate", %{"registration" => attrs}, socket) do
    changeset = socket |> registration_changeset(attrs) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :registration))}
  end

  def handle_event("submit", %{"registration" => attrs}, socket) do
    attrs = normalize_registration_attrs(attrs)

    if honeypot_filled?(attrs) do
      log_honeypot_hit(attrs, socket.assigns.user_agent, socket.assigns.real_ip)
      {:noreply, assign(socket, step: :email_sent)}
    else
      changeset = socket |> registration_changeset(attrs) |> Map.put(:action, :insert)
      {:noreply, apply_registration(socket, changeset)}
    end
  end

  # Only the Google step may create an account without an email round trip, and
  # the email must come from the verified identity. A connected LiveView outlives
  # the session entry, so the proof expiry is checked again here.
  def handle_event(
        "submit_google",
        %{"registration" => attrs},
        %{assigns: %{step: :google_form, google_identity: %{} = identity}} = socket
      ) do
    if identity_expired?(identity) do
      {:noreply, sign_up_error(socket, @google_session_error)}
    else
      changeset =
        attrs
        |> Map.put("email", identity.email)
        |> registration_changeset()
        |> Map.put(:action, :insert)

      {:noreply, apply_google_registration(socket, changeset)}
    end
  end

  def handle_event("submit_google", _params, socket) do
    {:noreply, sign_up_error(socket, @google_session_error)}
  end

  defp apply_google_registration(socket, %{valid?: true} = changeset) do
    registration = Ecto.Changeset.apply_changes(changeset)

    case Database.find_accounts_by_owner_email(registration.email) do
      [] ->
        registration = %{
          email: registration.email,
          account: %{name: registration.account.name},
          actor: %{name: registration.actor.name},
          identity: socket.assigns.google_identity,
          marketing_attribution: get_in(socket.assigns.website_attribution || %{}, ["marketing"])
        }

        handle_registration_result(
          socket,
          register_account(registration, socket.assigns.user_agent, socket.assigns.real_ip),
          socket.assigns.website_attribution
        )

      accounts ->
        existing_accounts_step(socket, accounts)
    end
  end

  defp apply_google_registration(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :registration))
  end

  defp start_google_sign_up(socket, identity) do
    changeset =
      registration_changeset(%{
        "email" => identity.email,
        "actor" => %{"name" => identity.profile_attrs["name"]}
      })

    if Keyword.has_key?(changeset.errors, :email) do
      sign_up_error(socket, @email_domain_error)
    else
      case Database.find_accounts_by_owner_email(identity.email) do
        [] -> assign(socket, step: :google_form, form: to_form(changeset, as: :registration))
        accounts -> existing_accounts_step(socket, accounts)
      end
    end
  end

  defp identity_expired?(%{expires_at: expires_at}), do: expires_at <= System.os_time(:second)

  defp existing_accounts_step(socket, accounts) do
    assign(socket, step: :existing_accounts, existing_accounts: accounts)
  end

  # Validation on the Google form uses the verified email so domain errors show early.
  defp registration_changeset(%{assigns: %{step: :google_form, google_identity: identity}}, attrs) do
    attrs
    |> Map.put("email", identity.email)
    |> registration_changeset()
  end

  defp registration_changeset(_socket, attrs), do: registration_changeset(attrs)

  defp registration_changeset(attrs) do
    attrs
    |> normalize_registration_attrs()
    |> Registration.changeset()
  end

  defp registration_form(attrs), do: to_form(registration_changeset(attrs), as: :registration)

  defp apply_registration(socket, %{valid?: true} = changeset) do
    registration = Ecto.Changeset.apply_changes(changeset)
    existing_accounts = Database.find_accounts_by_owner_email(registration.email)

    result =
      if existing_accounts == [] do
        send_verification_email(
          registration.email,
          registration.account.name,
          registration.actor.name,
          socket.assigns.website_attribution
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

  @spec send_verification_email(String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, any()} | {:error, any()}
  defp send_verification_email(email, company_name, actor_name, website_attribution) do
    payload = %{
      email: email,
      company_name: company_name,
      actor_name: actor_name,
      website_attribution: website_attribution
    }

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
         } = registration_claims,
         user_agent,
         real_ip
       ) do
    case Database.find_account_by_owner_email(email) do
      %Portal.Account{} = account ->
        redirect(socket, to: ~p"/#{account}/sign_in")

      nil ->
        registration = %{
          email: email,
          account: %{name: company_name},
          actor: %{name: actor_name},
          marketing_attribution: get_in(registration_claims, [:website_attribution, "marketing"])
        }

        handle_registration_result(
          socket,
          register_account(registration, user_agent, real_ip),
          Map.get(registration_claims, :website_attribution)
        )
    end
  end

  defp handle_registration_result(
         socket,
         {:ok, %{account: account, provider: provider, actor: actor} = result},
         website_attribution
       ) do
    Portal.Analytics.PostHog.identify_actor(actor, account, website_attribution)
    Portal.Analytics.registration_completed(account, actor)

    assign(socket,
      step: :account_created,
      account: account,
      provider: provider,
      google_provider: result.google_provider,
      actor: actor
    )
  end

  defp handle_registration_result(socket, {:error, :stripe_provision}, _website_attribution) do
    sign_up_error(socket, "We encountered a temporary error. Please try again.")
  end

  defp handle_registration_result(socket, {:error, _, _, _}, _website_attribution) do
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
      ExternalIdentity,
      Google,
      Safe,
      X509
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
      |> Safe.unscoped()
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
      |> Safe.unscoped()
      |> Safe.all()
    end

    @spec slug_exists?(String.t()) :: boolean()
    def slug_exists?(slug) do
      from(a in Portal.Account, where: a.slug == ^slug)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    # OTP 28 dialyzer is stricter about opaque types (MapSet) inside Ecto.Multi
    @dialyzer {:no_opaque, [register_account: 6, create_provider: 4]}
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
          metadata: %{
            stripe: stripe_metadata,
            marketing_attribution: registration[:marketing_attribution]
          }
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
      |> Ecto.Multi.run(:x509_provider, fn _repo, %{account: account} ->
        create_x509_provider(account)
      end)
      |> Ecto.Multi.run(:google_provider, fn _repo, %{account: account} ->
        create_google_provider(account, registration[:identity])
      end)
      |> Ecto.Multi.run(:actor, fn _repo, %{account: account} ->
        create_admin(account, registration.email, registration.actor.name)
      end)
      |> Ecto.Multi.run(:external_identity, fn _repo, %{account: account, actor: actor} ->
        create_external_identity(account, actor, registration[:identity])
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
      create_provider(account, :email_otp, EmailOTP.AuthProvider, %{name: "Email (OTP)"})
    end

    @spec create_x509_provider(Portal.Account.t()) ::
            {:ok, Portal.X509.AuthProvider.t()} | {:error, Ecto.Changeset.t()}
    def create_x509_provider(account) do
      create_provider(account, :x509, X509.AuthProvider, %{
        name: "X.509",
        context: :clients_only,
        is_disabled: true
      })
    end

    @spec create_google_provider(Portal.Account.t(), map() | nil) ::
            {:ok, map() | nil} | {:error, Ecto.Changeset.t()}
    def create_google_provider(_account, nil), do: {:ok, nil}

    def create_google_provider(account, identity) do
      create_provider(account, :google, Google.AuthProvider, %{
        issuer: identity.issuer,
        is_verified: true,
        is_default: true
      })
    end

    @spec create_external_identity(Portal.Account.t(), Portal.Actor.t(), map() | nil) ::
            {:ok, map() | nil} | {:error, Ecto.Changeset.t()}
    def create_external_identity(_account, _actor, nil), do: {:ok, nil}

    def create_external_identity(account, actor, identity) do
      attrs =
        Map.merge(identity.profile_attrs, %{
          "account_id" => account.id,
          "actor_id" => actor.id,
          "issuer" => identity.issuer,
          "idp_id" => identity.idp_id
        })

      %ExternalIdentity{}
      |> cast(
        attrs,
        ~w[account_id actor_id issuer idp_id email name given_name family_name middle_name nickname preferred_username profile picture]a
      )
      |> validate_required(~w[account_id actor_id issuer idp_id email name]a)
      |> ExternalIdentity.changeset()
      |> Safe.unscoped()
      |> Safe.insert()
    end

    defp create_provider(account, type, module, attrs) do
      id = Ecto.UUID.generate()

      parent_changeset =
        cast(
          %AuthProvider{},
          %{account_id: account.id, id: id, type: type},
          ~w[id account_id type]a
        )

      attrs = Map.merge(attrs, %{id: id, account_id: account.id})

      provider_changeset =
        module
        |> struct()
        |> cast(attrs, Map.keys(attrs))
        |> module.changeset()

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:auth_provider, parent_changeset)
      |> Ecto.Multi.insert(:provider, provider_changeset)
      |> Safe.transact()
      |> case do
        {:ok, %{provider: provider}} -> {:ok, provider}
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
