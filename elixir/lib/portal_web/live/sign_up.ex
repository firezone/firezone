defmodule PortalWeb.SignUp do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :public}}
  alias Portal.{Accounts, Actor, Config}
  alias PortalWeb.Registration
  alias __MODULE__.Database

  defmodule Registration do
    use Ecto.Schema
    @primary_key false
    @foreign_key_type :binary_id
    @timestamps_opts [type: :utc_datetime_usec]

    alias Portal.Accounts

    import Ecto.Changeset
    import Portal.Changeset

    embedded_schema do
      field(:email, :string)
      embeds_one(:account, Portal.Account)
      embeds_one(:actor, Actor)
    end

    def changeset(attrs) do
      whitelisted_domains = Portal.Config.get_env(:portal, :sign_up_whitelisted_domains)

      %Registration{}
      |> cast(attrs, [:email])
      |> validate_required([:email])
      |> trim_change(:email)
      |> validate_email(:email)
      |> validate_email_allowed(whitelisted_domains)
      |> validate_confirmation(:email,
        required: true,
        message: "email does not match"
      )
      |> cast_embed(:account,
        with: fn _account, attrs -> create_account_changeset(attrs) end
      )
      |> cast_embed(:actor,
        with: fn _actor, attrs -> create_actor_changeset(attrs) end
      )
    end

    defp create_account_changeset(attrs) do
      %Portal.Account{}
      |> cast(attrs, [:name, :legal_name, :slug])
      |> Portal.Account.changeset()
      |> put_default_value(:config, %Accounts.Config{})
    end

    defp create_actor_changeset(attrs) do
      %Portal.Actor{}
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 255)
    end

    defp validate_email_allowed(changeset, []) do
      changeset
    end

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

  def mount(_params, _session, socket) do
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
    real_ip = PortalWeb.Authentication.real_ip(socket)
    sign_up_enabled? = Config.sign_up_enabled?()

    changeset =
      Registration.changeset(%{
        account: %{slug: "placeholder"},
        actor: %{type: :account_admin_user}
      })

    socket =
      assign(socket,
        page_title: "Sign Up",
        form: to_form(changeset),
        account: nil,
        provider: nil,
        user_agent: user_agent,
        real_ip: real_ip,
        sign_up_enabled?: sign_up_enabled?
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.hero_logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />

            <.intersperse_blocks>
              <:separator>
                <.separator />
              </:separator>

              <:item>
                <.sign_up_form :if={@account == nil && @sign_up_enabled?} flash={@flash} form={@form} />
                <.welcome
                  :if={@account && @sign_up_enabled?}
                  account={@account}
                  provider={@provider}
                  actor={@actor}
                />
                <.sign_up_disabled :if={!@sign_up_enabled?} />
              </:item>
            </.intersperse_blocks>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def separator(assigns) do
    ~H"""
    <div class="flex items-center">
      <div class="w-full h-0.5 bg-neutral-200"></div>
      <div class="px-5 text-center text-neutral-500">or</div>
      <div class="w-full h-0.5 bg-neutral-200"></div>
    </div>
    """
  end

  def welcome(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-center text-neutral-900">
        <p class="text-xl font-medium">Your account has been created!</p>
        <p>Please check your email for sign in instructions.</p>
      </div>
      <div class="text-center">
        <div class="px-12">
          <table class="border-collapse w-full text-sm">
            <tbody>
              <tr>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900 font-bold]}>
                  Account Name:
                </td>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  {@account.name}
                </td>
              </tr>
              <tr>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900 font-bold]}>
                  Account Slug:
                </td>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  {@account.slug}
                </td>
              </tr>
              <tr>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900 font-bold]}>
                  Sign In URL:
                </td>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  <.link class={[link_style()]} navigate={~p"/#{@account}"}>
                    {url(~p"/#{@account}")}
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <div class="text-base text-center text-neutral-900">
        <.form
          for={%{}}
          id="resend-email"
          as={:email}
          class="inline"
          action={~p"/#{@account}/sign_in/email_otp/#{@provider}"}
          method="post"
        >
          <.input
            type="hidden"
            name="email"
            value={@actor.email}
          />

          <.button type="submit" class="w-full">
            Sign In
          </.button>
        </.form>
      </div>
    </div>
    """
  end

  def sign_up_form(assigns) do
    ~H"""
    <h2 class="text-lg sm:text-xl leading-tight tracking-tight text-neutral-900">
      Sign up for a new account
    </h2>
    <.form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="validate">
      <div class="bg-white grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
        <.input
          field={@form[:email]}
          type="text"
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
          <.input field={account[:slug]} type="hidden" />
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
      </div>

      <.button phx-disable-with="Creating Account..." class="w-full">
        Create Account
      </.button>

      <p class="text-xs text-center">
        By signing up you agree to our <.link
          href="https://www.firezone.dev/terms"
          class={link_style()}
        >Terms of Use</.link>.
      </p>

      <p class="py-2 text-center">
        Already have an account?
        <a href={~p"/"} class={[link_style()]}>
          Sign in here.
        </a>
      </p>
    </.form>
    """
  end

  def sign_up_disabled(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-xl text-center text-neutral-900">
        Sign-ups are currently disabled.
      </div>
      <div class="text-center">
        Please contact
        <a class={link_style()} href="mailto:sales@firezone.dev?subject=Firezone Sign Up Request">
          sales@firezone.dev
        </a>
        for more information.
      </div>
      <p class="text-xs text-center">
        By signing up you agree to our <.link
          href="https://www.firezone.dev/terms"
          class={link_style()}
        >Terms of Use</.link>.
      </p>
    </div>
    """
  end

  def handle_event("validate", %{"registration" => attrs}, socket) do
    attrs = Map.put(attrs, "email_confirmation", attrs["email"])

    changeset =
      attrs
      |> Registration.changeset()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"registration" => orig_attrs}, socket) do
    attrs =
      put_in(orig_attrs, ["actor", "type"], :account_admin_user)
      |> Map.put("email_confirmation", orig_attrs["email"])
      |> Map.put("slug", "placeholder")

    changeset =
      attrs
      |> put_in(["actor", "type"], :account_admin_user)
      |> Registration.changeset()
      |> Map.put(:action, :insert)

    if changeset.valid? and socket.assigns.sign_up_enabled? do
      registration = Ecto.Changeset.apply_changes(changeset)

      case register_account(socket, registration) do
        {:ok, %{account: account, provider: provider, actor: actor}} ->
          {:ok, account} = Portal.Billing.provision_account(account)

          socket =
            assign(socket,
              account: account,
              provider: provider,
              actor: actor
            )

          socket =
            push_event(socket, "identify", %{
              id: actor.id,
              account_id: account.id,
              name: actor.name,
              email: actor.email
            })

          socket =
            push_event(socket, "track_event", %{
              name: "Sign Up",
              properties: %{
                account_id: account.id,
                actor_id: actor.id
              }
            })

          {:noreply, socket}

        {:error, :send_email, :rate_limited, _effects_so_far} ->
          changeset =
            Ecto.Changeset.add_error(
              changeset,
              :email,
              "This email has been rate limited. Please try again later."
            )

          {:noreply, assign(socket, form: to_form(changeset))}

        {:error, :send_email, _reason, _effects_so_far} ->
          changeset =
            Ecto.Changeset.add_error(
              changeset,
              :email,
              "We were unable to send you an email. Please try again later."
            )

          {:noreply, assign(socket, form: to_form(changeset))}

        {:error, :account, error_changeset, _effects_so_far} ->
          new_changeset = Ecto.Changeset.put_change(changeset, :account, error_changeset)
          form = to_form(new_changeset)
          {:noreply, assign(socket, form: form)}
      end
    else
      {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp create_account_changeset(attrs) do
    import Ecto.Changeset

    %Portal.Account{}
    |> cast(attrs, [:name, :legal_name, :slug])
    |> maybe_default_legal_name()
    |> maybe_generate_slug()
    |> put_default_config()
    |> cast_embed(:metadata)
    |> validate_required([:name, :legal_name, :slug])
    |> Portal.Account.changeset()
  end

  defp put_default_config(changeset) do
    import Ecto.Changeset

    # Initialize with default config
    default_config = Portal.Accounts.Config.default_config()
    put_change(changeset, :config, default_config)
  end

  defp maybe_generate_slug(changeset) do
    import Ecto.Changeset

    case get_field(changeset, :slug) do
      nil ->
        # Generate a unique slug
        slug = generate_unique_slug()
        put_change(changeset, :slug, slug)

      "placeholder" ->
        # Replace placeholder with a real slug
        slug = generate_unique_slug()
        put_change(changeset, :slug, slug)

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
        # Default legal_name to name if not provided
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

  defp register_account(socket, registration) do
    Database.register_account(
      registration,
      &create_account_changeset/1,
      &create_everyone_group_changeset/1,
      &create_site_changeset/2,
      &create_internet_site_changeset/1,
      &create_internet_resource_changeset/2,
      socket.assigns.user_agent,
      socket.assigns.real_ip
    )
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

    attrs = %{
      type: :internet,
      name: "Internet"
    }

    %Portal.Resource{account_id: account.id, site_id: site.id}
    |> cast(attrs, [:type, :name])
    |> validate_required([:name, :type])
  end

  defmodule Database do
    import Ecto.Changeset

    alias Portal.{
      Actor,
      AuthProvider,
      EmailOTP,
      Repo
    }

    # OTP 28 dialyzer is stricter about opaque types (MapSet) inside Ecto.Multi
    @dialyzer {:no_opaque, [register_account: 8, create_email_provider: 1]}
    def register_account(
          registration,
          account_changeset_fn,
          everyone_group_changeset_fn,
          site_changeset_fn,
          internet_site_changeset_fn,
          internet_resource_changeset_fn,
          user_agent,
          real_ip
        ) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:account, fn _repo, _changes ->
        %{
          name: registration.account.name,
          metadata: %{stripe: %{billing_email: registration.email}}
        }
        |> account_changeset_fn.()
        |> insert()
      end)
      |> Ecto.Multi.run(:everyone_group, fn _repo, %{account: account} ->
        everyone_group_changeset_fn.(account)
        |> insert()
      end)
      |> Ecto.Multi.run(:provider, fn _repo, %{account: account} ->
        create_email_provider(account)
      end)
      |> Ecto.Multi.run(:actor, fn _repo, %{account: account} ->
        create_admin(account, registration.email, registration.actor.name)
      end)
      |> Ecto.Multi.run(:default_site, fn _repo, %{account: account} ->
        site_changeset_fn.(account, %{name: "Default Site"})
        |> insert()
      end)
      |> Ecto.Multi.run(:internet_site, fn _repo, %{account: account} ->
        internet_site_changeset_fn.(account)
        |> insert()
      end)
      |> Ecto.Multi.run(:internet_resource, fn _repo,
                                               %{account: account, internet_site: internet_site} ->
        internet_resource_changeset_fn.(account, internet_site)
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
      |> Repo.transact()
    end

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
      |> Repo.transact()
      |> case do
        {:ok, %{email_otp_provider: email_provider}} -> {:ok, email_provider}
        {:error, _step, changeset, _changes} -> {:error, changeset}
      end
    end

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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.insert()
    end

    def insert(changeset) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.insert(changeset)
    end

    def slug_exists?(slug) do
      import Ecto.Query

      query = from(a in Portal.Account, where: a.slug == ^slug, select: count(a.id))
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.exists?(query)
    end
  end
end
