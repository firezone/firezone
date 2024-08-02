defmodule Web.TempAccounts.Index do
  use Web, {:live_view, layout: {Web.Layouts, :public}}
  alias Domain.{Accounts, Actors, Auth, Config}

  def mount(_params, _session, socket) do
    if Config.global_feature_enabled?(:temp_accounts) do
      socket =
        assign(socket,
          page_title: "Try Firezone",
          account_info: nil,
          creation_error: false
        )

      {:ok, socket}
    else
      raise(Web.LiveErrors.NotFoundError)
    end
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.hero_logo text="Welcome to Firezone" />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <.flash flash={@flash} kind={:error} />
            <.flash flash={@flash} kind={:info} />
            <.welcome :if={is_nil(@account_info) and @creation_error == false} />
            <.account
              :if={not is_nil(@account_info)}
              account={@account_info.account}
              password={@account_info.password}
            />
            <div :if={@creation_error}>
              Something went wrong!
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def welcome(assigns) do
    ~H"""
    <div class="text-center">
      <p class="mb-4">
        Interested in trying out Firezone?  You've come to the right place!
      </p>

      <p class="mb-4">
        Take Firezone for a spin with a temporary demo account.
      </p>
      <div class="py-1">
        <.button class="w-full" phx-click="start">Create Temporary Account</.button>
      </div>

      <div class="flex items-center my-6">
        <div class="w-full h-0.5 bg-neutral-200"></div>
        <div class="px-5 text-center text-neutral-500">or</div>
        <div class="w-full h-0.5 bg-neutral-200"></div>
      </div>

      <p class="mb-4">
        Sign up below with a free starter account to keep your data.
      </p>
      <p>
        <a
          class="inline-block bg-white border rounded px-3 py-2 text-sm w-full"
          href={url(~p"/sign_up")}
        >
          Create Free Starter Account
        </a>
      </p>
    </div>
    """
  end

  attr :account, :any
  attr :password, :string

  def account(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-center text-neutral-900 text-xl">
        Your temporary account has been created!
      </div>
      <.flash kind={:warning}>
        <p class="flex items-center gap-1.5 text-sm font-semibold leading-6">
          <span class="hero-exclamation-triangle h-4 w-4"></span> Warning!
        </p>
        <div>Please save the following information, it will not be displayed again.</div>
      </.flash>
      <div class="text-center">
        <div>
          <.code_block
            id="code-sample-systemd0"
            class="w-full text-xs whitespace-pre-line rounded"
            phx-no-format
          ><%= account_details(@account, @password) %></.code_block>
        </div>
      </div>
      <div class="text-base text-center text-neutral-900">
        <.link class={button_style("primary") ++ ["py-2"]} navigate={~p"/#{@account}"}>
          Sign In
        </.link>
      </div>
    </div>
    """
  end

  def handle_event("start", _params, socket) do
    case register_temp_account() do
      {:ok, account_info} ->
        socket =
          socket
          |> assign(:account_info, account_info)

        {:noreply, socket}

      {:error, _} ->
        socket =
          socket
          |> assign(:creation_error, true)

        {:noreply, socket}
    end
  end

  defp register_temp_account do
    account_name = random_string(12)
    account_slug = "temp_" <> account_name
    admin_email = "admin_#{account_slug}@firezonedemo.com"
    admin_password = random_string(16)

    Ecto.Multi.new()
    |> Ecto.Multi.run(
      :account,
      fn _repo, _changes ->
        Accounts.create_account(%{
          name: "Temp Account #{account_name}",
          slug: account_slug,
          metadata: %{stripe: %{billing_email: admin_email}}
        })
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
          name: "Temp Account Password",
          adapter: :temp_account,
          adapter_config: %{}
        })
      end
    )
    |> Ecto.Multi.run(
      :actor,
      fn _repo, %{account: account} ->
        Actors.create_actor(account, %{
          type: :account_admin_user,
          name: "Admin #{account_slug}"
        })
      end
    )
    |> Ecto.Multi.run(
      :identity,
      fn _repo, %{actor: actor, provider: provider} ->
        Auth.create_identity(actor, provider, %{
          provider_identifier: admin_email,
          provider_virtual_state: %{
            "password" => admin_password,
            "password_confirmation" => admin_password
          }
        })
      end
    )
    |> Ecto.Multi.run(
      :password,
      fn _repo, %{} -> {:ok, admin_password} end
    )
    |> Domain.Repo.transaction()
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode32()
    |> binary_part(0, length)
    |> String.downcase()
  end

  defp account_details(account, password) do
    """
    Account Name: #{account.name}

    Account Slug: #{account.slug}

    Account URL: #{url(~p"/#{account}")}

    Account Password: #{password}
    """
  end
end
