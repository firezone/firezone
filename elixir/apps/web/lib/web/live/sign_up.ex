defmodule Web.SignUp do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  alias Domain.{Auth, Accounts, Actors}
  alias Web.Registration

  def mount(_params, _session, socket) do
    temp_acct_slug = Accounts.generate_unique_slug()

    changeset =
      Registration.changeset(%Registration{}, %{
        account: %{slug: temp_acct_slug},
        actor: %{type: :account_admin_user}
      })

    {:ok, assign(socket, form: to_form(changeset), account: nil)}
  end

  def render(assigns) do
    ~H"""
    <section class="bg-gray-50 dark:bg-gray-900">
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded-lg shadow dark:bg-gray-800 md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-center text-xl font-bold leading-tight tracking-tight text-gray-900 sm:text-2xl dark:text-white">
              Welcome to Firezone
            </h1>

            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />

            <.intersperse_blocks>
              <:separator>
                <.separator />
              </:separator>

              <:item>
                <.sign_up_form :if={@account == nil} flash={@flash} form={@form} />
                <.welcome :if={@account} account={@account} />
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
      <div class="w-full h-0.5 bg-gray-200 dark:bg-gray-700"></div>
      <div class="px-5 text-center text-gray-500 dark:text-gray-400">or</div>
      <div class="w-full h-0.5 bg-gray-200 dark:bg-gray-700"></div>
    </div>
    """
  end

  def welcome(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-center text-gray-900 dark:text-white">
        Your account has been created!
      </div>
      <div class="text-center">
        <div class="px-12">
          <table class="border-collapse table-fixed w-full text-sm">
            <tbody>
              <tr>
                <td class={~w[border-b border-slate-100 dark:border-slate-700
                              p-4 pl-8 text-gray-900 dark:text-white]}>
                  Account Name:
                </td>
                <td class={~w[border-b border-slate-100 dark:border-slate-700
                              p-4 pl-8 text-gray-900 dark:text-white]}>
                  <%= @account.name %>
                </td>
              </tr>
              <tr>
                <td class={~w[border-b border-slate-100 dark:border-slate-700
                              p-4 pl-8 text-gray-900 dark:text-white]}>
                  Account Slug:
                </td>
                <td class={~w[border-b border-slate-100 dark:border-slate-700
                              p-4 pl-8 text-gray-900 dark:text-white]}>
                  <%= @account.slug %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <div class="text-base leading-7 text-center text-gray-900 dark:text-white">
        <div>
          Sign In URL
        </div>
        <div>
          <.link
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            navigate={~p"/#{@account.slug}/sign_in"}
          >
            <%= "#{Web.Endpoint.url()}/#{@account.slug}/sign_in" %>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  def sign_up_form(assigns) do
    ~H"""
    <h3 class="text-center text-m font-bold leading-tight tracking-tight text-gray-900 sm:text-xl dark:text-white">
      Sign Up Now
    </h3>
    <.simple_form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="validate">
      <.inputs_for :let={account} field={@form[:account]}>
        <.input
          field={account[:name]}
          type="text"
          label="Account Name"
          placeholder="Enter an Account Name here"
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

      <.input
        field={@form[:email]}
        type="text"
        label="Email"
        placeholder="Enter your email here"
        required
        phx-debounce="300"
      />

      <:actions>
        <.button phx-disable-with="Creating Account..." class="w-full">
          Create Account
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  def handle_event("validate", %{"registration" => attrs}, socket) do
    changeset =
      %Registration{}
      |> Web.Registration.changeset(attrs)
      |> Map.put(:action, :validate)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  def handle_event("submit", %{"registration" => orig_attrs}, socket) do
    attrs = put_in(orig_attrs, ["actor", "type"], :account_admin_user)

    changeset =
      %Registration{}
      |> Web.Registration.changeset(attrs)
      |> Map.put(:action, :insert)

    if changeset.valid? do
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
              name: "Magic Link",
              adapter: :email,
              adapter_config: %{}
            })
          end
        )
        |> Ecto.Multi.run(
          :actor,
          fn _repo, %{provider: provider} ->
            Actors.create_actor(provider, registration.email, %{
              type: :account_admin_user,
              name: registration.actor.name
            })
          end
        )

      Domain.Repo.transaction(multi)
      |> case do
        {:ok, result} ->
          socket = assign(socket, account: result.account)
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
end
