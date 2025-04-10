defmodule Web.SignUp do
  use Web, {:live_view, layout: {Web.Layouts, :public}}
  alias Domain.{Auth, Accounts, Actors, Config}
  alias Web.Registration

  defmodule Registration do
    use Domain, :schema

    alias Domain.{Accounts, Actors}

    @primary_key false

    embedded_schema do
      field(:email, :string)
      embeds_one(:account, Accounts.Account)
      embeds_one(:actor, Actors.Actor)
    end

    def changeset(attrs) do
      whitelisted_domains = Domain.Config.get_env(:domain, :sign_up_whitelisted_domains)

      %Registration{}
      |> Ecto.Changeset.cast(attrs, [:email])
      |> Ecto.Changeset.validate_required([:email])
      |> Domain.Repo.Changeset.trim_change(:email)
      |> Domain.Repo.Changeset.validate_email(:email)
      |> validate_email_allowed(whitelisted_domains)
      |> Ecto.Changeset.validate_confirmation(:email,
        required: true,
        message: "email does not match"
      )
      |> Ecto.Changeset.cast_embed(:account,
        with: fn _account, attrs -> Accounts.Account.Changeset.create(attrs) end
      )
      |> Ecto.Changeset.cast_embed(:actor,
        with: fn _account, attrs -> Actors.Actor.Changeset.create(attrs) end
      )
    end

    defp validate_email_allowed(changeset, []) do
      changeset
    end

    defp validate_email_allowed(changeset, whitelisted_domains) do
      Ecto.Changeset.validate_change(changeset, :email, fn :email, email ->
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
    real_ip = Web.Auth.real_ip(socket)
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
        sign_up_enabled?: sign_up_enabled?,
        account_name_changed?: false,
        actor_name_changed?: false
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
                  identity={@identity}
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
          action={~p"/#{@account}/sign_in/providers/#{@provider}/request_email_otp"}
          method="post"
        >
          <.input
            type="hidden"
            name="email[provider_identifier]"
            value={@identity.provider_identifier}
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

  def handle_event("validate", %{"registration" => attrs} = payload, socket) do
    account_name_changed? =
      socket.assigns.account_name_changed? ||
        payload["_target"] == ["registration", "account", "name"]

    actor_name_changed? =
      socket.assigns.actor_name_changed? ||
        payload["_target"] == ["registration", "actor", "name"]

    attrs = Map.put(attrs, "email_confirmation", attrs["email"])

    changeset =
      attrs
      |> Registration.changeset()
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       account_name_changed?: account_name_changed?,
       actor_name_changed?: actor_name_changed?
     )}
  end

  def handle_event("submit", %{"registration" => orig_attrs}, socket) do
    attrs =
      put_in(orig_attrs, ["actor", "type"], :account_admin_user)
      |> Map.put("email_confirmation", orig_attrs["email"])

    changeset =
      attrs
      |> put_in(["actor", "type"], :account_admin_user)
      |> Registration.changeset()
      |> Map.put(:action, :insert)

    if changeset.valid? and socket.assigns.sign_up_enabled? do
      registration = Ecto.Changeset.apply_changes(changeset)

      case register_account(socket, registration) do
        {:ok, %{account: account, provider: provider, identity: identity, actor: actor}} ->
          socket =
            assign(socket,
              account: account,
              provider: provider,
              identity: identity
            )

          socket =
            push_event(socket, "identify", %{
              id: actor.id,
              account_id: account.id,
              name: actor.name,
              email: identity.provider_identifier
            })

          socket =
            push_event(socket, "track_event", %{
              name: "Sign Up",
              properties: %{
                account_id: account.id,
                identity_id: identity.id
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

  defp register_account(socket, registration) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(
      :account,
      fn _repo, _changes ->
        Accounts.create_account(%{name: registration.account.name})
      end
    )
    |> Ecto.Multi.run(:everyone_group, fn _repo, %{account: account} ->
      Domain.Actors.create_managed_group(account, %{
        name: "Everyone",
        membership_rules: [%{operator: true}]
      })
    end)
    |> Ecto.Multi.run(
      :provider,
      fn _repo, %{account: account} ->
        Auth.create_provider(account, %{
          name: "Email",
          adapter: :email,
          adapter_config: %{}
        })
      end
    )
    |> Ecto.Multi.run(
      :actor,
      fn _repo, %{account: account} ->
        Actors.create_actor(account, %{
          type: :account_admin_user,
          name: registration.actor.name
        })
      end
    )
    |> Ecto.Multi.run(
      :identity,
      fn _repo, %{actor: actor, provider: provider} ->
        Auth.create_identity(actor, provider, %{
          provider_identifier: registration.email,
          provider_identifier_confirmation: registration.email
        })
      end
    )
    |> Ecto.Multi.run(
      :default_site,
      fn _repo, %{account: account} ->
        Domain.Gateways.create_group(account, %{name: "Default Site"})
      end
    )
    |> Ecto.Multi.run(
      :internet_site,
      fn _repo, %{account: account} ->
        Domain.Gateways.create_internet_group(account)
      end
    )
    |> Ecto.Multi.run(
      :internet_resource,
      fn _repo, %{account: account, internet_site: internet_site} ->
        Domain.Resources.create_internet_resource(account, internet_site)
      end
    )
    |> Ecto.Multi.run(
      :send_email,
      fn _repo, %{account: account, identity: identity} ->
        Domain.Mailer.AuthEmail.sign_up_link_email(
          account,
          identity,
          socket.assigns.user_agent,
          socket.assigns.real_ip
        )
        |> Domain.Mailer.deliver_with_rate_limit(
          rate_limit_key: {:sign_up_link, String.downcase(identity.provider_identifier)},
          rate_limit: 3,
          rate_limit_interval: :timer.minutes(30)
        )
      end
    )
    |> Domain.Repo.transaction()
  end
end
