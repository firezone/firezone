defmodule Domain.Ops do
  import Ecto.Changeset
  alias __MODULE__.DB
  alias Domain.Banner

  def create_and_provision_account(opts) do
    %{
      name: account_name,
      slug: account_slug,
      admin_name: account_admin_name,
      admin_email: account_admin_email
    } = Enum.into(opts, %{})

    Domain.Repo.transaction(fn ->
      {:ok, account} =
        Domain.Accounts.create_account(%{
          name: account_name,
          slug: account_slug,
          metadata: %{
            stripe: %{
              billing_email: account_admin_email
            }
          }
        })

      {:ok, account} = Domain.Billing.provision_account(account)

      {:ok, _everyone_group} =
        Domain.Actors.create_managed_group(account, %{
          name: "Everyone"
        })

      {:ok, email_provider} =
        Domain.Auth.create_provider(account, %{
          name: "Email",
          adapter: :email,
          adapter_config: %{}
        })

      {:ok, actor} =
        Domain.Actors.create_actor(account, %{
          type: :account_admin_user,
          name: account_admin_name
        })

      {:ok, identity} =
        Domain.Auth.upsert_identity(actor, email_provider, %{
          provider_identifier: account_admin_email,
          provider_identifier_confirmation: account_admin_email
        })

      %{account: account, provider: email_provider, actor: actor, identity: identity}
    end)
  end

  def provision_account_user(account_id, type, name, email) do
    account = Domain.Accounts.fetch_account_by_id!(account_id)

    provider =
      Domain.Auth.all_active_providers_for_account!(account)
      |> Enum.find(fn provider -> provider.adapter == :email end)

    {:ok, actor} =
      Domain.Actors.create_actor(account, %{
        type: type,
        name: name
      })

    {:ok, identity} =
      Domain.Auth.upsert_identity(actor, provider, %{
        provider_identifier: email,
        provider_identifier_confirmation: email
      })

    {:ok, %{actor: actor, identity: identity}}
  end

  def provision_support_by_account_slug(account_slug) do
    Domain.Repo.transaction(fn ->
      {:ok, account} = Domain.Accounts.fetch_account_by_id_or_slug(account_slug)
      providers = Domain.Auth.all_active_providers_for_account!(account)
      email_provider = Enum.find(providers, fn provider -> provider.adapter == :email end)

      {:ok, actor} =
        Domain.Actors.create_actor(account, %{type: :account_admin_user, name: "Firezone Support"})

      {:ok, identity} =
        Domain.Auth.upsert_identity(actor, email_provider, %{
          provider_identifier: "ent-support@firezone.dev",
          provider_identifier_confirmation: "ent-support@firezone.dev"
        })

      {actor, identity}
    end)
  end

  def sync_pricing_plans do
    {:ok, subscriptions} = Domain.Billing.list_all_subscriptions()

    Enum.each(subscriptions, fn subscription ->
      %{
        "object" => "event",
        "data" => %{
          "object" => subscription
        },
        "type" => "customer.subscription.updated"
      }
      |> Domain.Billing.EventHandler.handle_event()
    end)
  end

  @doc """
  To delete an account you need to disable it first by cancelling its subscription in Stripe.
  """
  def delete_disabled_account(id) do
    Domain.Accounts.Account.Query.all()
    |> Domain.Accounts.Account.Query.disabled()
    |> Domain.Accounts.Account.Query.by_id(id)
    |> Domain.Repo.one!()
    |> Domain.Repo.delete(timeout: :infinity)

    :ok
  end

  def set_banner(message) do
    cast(%Banner{}, %{message: message}, [:message])
    |> DB.insert()
  end

  def clear_banner do
    DB.delete_all(Banner)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Repo

    def insert(changeset) do
      changeset
      |> Repo.insert()
    end

    def delete_all(schema) do
      from(s in schema)
      |> Repo.delete_all()
    end
  end
end
