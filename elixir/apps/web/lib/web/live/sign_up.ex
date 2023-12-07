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
      %Registration{}
      |> Ecto.Changeset.cast(attrs, [:email])
      |> Ecto.Changeset.validate_required([:email])
      |> Ecto.Changeset.validate_format(:email, ~r/.+@.+/)
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
  end

  def mount(_params, _session, socket) do
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
    real_ip = Web.Auth.real_ip(socket)

    changeset =
      Registration.changeset(%{
        account: %{slug: "placeholder"},
        actor: %{type: :account_admin_user}
      })

    socket =
      assign(socket,
        form: to_form(changeset),
        account: nil,
        provider: nil,
        user_agent: user_agent,
        real_ip: real_ip,
        sign_up_enabled?: Config.sign_up_enabled?(),
        account_name_changed?: false,
        actor_name_changed?: false
      )

    {:ok, socket}

    {:ok, assign(socket, form: to_form(changeset), account: nil)}
  end

  def render(assigns) do
    ~H"""
    <section class="bg-neutral-50">
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-center text-xl font-bold leading-tight tracking-tight text-neutral-900 sm:text-2xl">
              Welcome to Firezone
            </h1>

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
        Your account has been created!
        <p>Please check your email for sign in instructions.</p>
      </div>
      <div class="text-center">
        <div class="px-12">
          <table class="border-collapse w-full text-sm">
            <tbody>
              <tr>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  Account Name:
                </td>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  <%= @account.name %>
                </td>
              </tr>
              <tr>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  Account Slug:
                </td>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  <%= @account.slug %>
                </td>
              </tr>
              <tr>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  Sign In URL:
                </td>
                <td class={~w[border-b border-neutral-100 py-4 text-neutral-900]}>
                  <.link class={["font-medium", link_style()]} navigate={~p"/#{@account}"}>
                    <%= url(~p"/#{@account}") %>
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <div class="text-base leading-7 text-center text-neutral-900">
        <.form
          for={%{}}
          id="resend-email"
          as={:email}
          class="inline"
          action={~p"/#{@account}/sign_in/providers/#{@provider}/request_magic_link"}
          method="post"
        >
          <.input
            type="hidden"
            name="email[provider_identifier]"
            value={@identity.provider_identifier}
          />
          <.submit_button class="w-full">
            Sign In
          </.submit_button>
        </.form>
      </div>
    </div>
    """
  end

  def sign_up_form(assigns) do
    ~H"""
    <h3 class="text-center text-m font-bold leading-tight tracking-tight text-neutral-900 sm:text-xl">
      Sign Up Now
    </h3>
    <.simple_form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="validate">
      <.input
        field={@form[:email]}
        type="text"
        label="Email"
        placeholder="Enter your work email here"
        required
        autofocus
        phx-debounce="300"
      />

      <.inputs_for :let={account} field={@form[:account]}>
        <.input
          field={account[:name]}
          type="text"
          label="Account Name"
          placeholder="Enter an account name"
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
          placeholder="Enter your name here"
          required
          phx-debounce="300"
        />
        <.input field={actor[:type]} type="hidden" />
      </.inputs_for>

      <:actions>
        <.button phx-disable-with="Creating Account..." class="w-full">
          Create Account
        </.button>
      </:actions>
      <p class="text-xs text-center">
        By signing up you agree to our <.link
          href="https://www.firezone.dev/terms"
          class={link_style()}
        >Terms of Use</.link>.
      </p>
    </.simple_form>
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
      |> maybe_put_default_account_name(account_name_changed?)
      |> maybe_put_default_actor_name(actor_name_changed?)
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
      |> maybe_put_default_account_name()
      |> maybe_put_default_actor_name()
      |> put_in(["actor", "type"], :account_admin_user)
      |> Registration.changeset()
      |> Map.put(:action, :insert)

    if changeset.valid? && socket.assigns.sign_up_enabled? do
      registration = Ecto.Changeset.apply_changes(changeset)

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(
          :account,
          fn _repo, _changes ->
            Accounts.create_account(%{
              name: registration.account.name
            })
          end
        )
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

      case Domain.Repo.transaction(multi) do
        {:ok, %{account: account, provider: provider, identity: identity}} ->
          {:ok, _} =
            Web.Mailer.AuthEmail.sign_up_link_email(
              account,
              identity,
              socket.assigns.user_agent,
              socket.assigns.real_ip
            )
            |> Web.Mailer.deliver()

          socket = assign(socket, account: account, provider: provider, identity: identity)
          {:noreply, socket}

        {:error, :account, err_changeset, _effects_so_far} ->
          new_changeset = Ecto.Changeset.put_change(changeset, :account, err_changeset)
          form = to_form(new_changeset)

          {:noreply, assign(socket, form: form)}
      end
    else
      {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp maybe_put_default_account_name(attrs, account_name_changed? \\ true)

  defp maybe_put_default_account_name(attrs, true) do
    attrs
  end

  defp maybe_put_default_account_name(attrs, false) do
    case String.split(attrs["email"], "@", parts: 2) do
      [default_name | _] when byte_size(default_name) > 0 ->
        put_in(attrs, ["account", "name"], "#{default_name}'s account")

      _ ->
        attrs
    end
  end

  defp maybe_put_default_actor_name(attrs, actor_name_changed? \\ true)

  defp maybe_put_default_actor_name(attrs, true) do
    attrs
  end

  defp maybe_put_default_actor_name(attrs, false) do
    [default_name | _] = String.split(attrs["email"], "@", parts: 2)
    put_in(attrs, ["actor", "name"], default_name)
  end
end
