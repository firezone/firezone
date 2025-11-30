defmodule Domain.Billing do
  use Supervisor
  alias Domain.Auth
  alias Domain.Billing.EventHandler
  alias Domain.Billing.Stripe.APIClient
  alias __MODULE__.DB
  require Logger

  # Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      APIClient
    ]

    if enabled?() do
      Supervisor.init(children, strategy: :one_for_one)
    else
      :ignore
    end
  end

  # Configuration helpers

  def enabled? do
    fetch_config!(:enabled)
  end

  def fetch_webhook_signing_secret! do
    fetch_config!(:webhook_signing_secret)
  end

  # Limits and Features

  def users_limit_exceeded?(%Domain.Account{} = account, users_count) do
    not is_nil(account.limits.users_count) and
      users_count > account.limits.users_count
  end

  def seats_limit_exceeded?(%Domain.Account{} = account, active_users_count) do
    not is_nil(account.limits.monthly_active_users_count) and
      active_users_count > account.limits.monthly_active_users_count
  end

  def can_create_users?(%Domain.Account{} = account) do
    users_count = DB.count_users_for_account(account)
    active_users_count = DB.count_1m_active_users_for_account(account)

    cond do
      not Domain.Account.active?(account) ->
        false

      not is_nil(account.limits.monthly_active_users_count) ->
        active_users_count < account.limits.monthly_active_users_count

      not is_nil(account.limits.users_count) ->
        users_count < account.limits.users_count

      true ->
        true
    end
  end

  def service_accounts_limit_exceeded?(%Domain.Account{} = account, service_accounts_count) do
    not is_nil(account.limits.service_accounts_count) and
      service_accounts_count > account.limits.service_accounts_count
  end

  def can_create_service_accounts?(%Domain.Account{} = account) do
    service_accounts_count = DB.count_service_accounts_for_account(account)

    Domain.Account.active?(account) and
      (is_nil(account.limits.service_accounts_count) or
         service_accounts_count < account.limits.service_accounts_count)
  end

  def sites_limit_exceeded?(%Domain.Account{} = account, sites_count) do
    not is_nil(account.limits.sites_count) and
      sites_count > account.limits.sites_count
  end

  def can_create_sites?(%Domain.Account{} = account) do
    sites_count = DB.count_sites_for_account(account)

    Domain.Account.active?(account) and
      (is_nil(account.limits.sites_count) or
         sites_count < account.limits.sites_count)
  end

  def admins_limit_exceeded?(%Domain.Account{} = account, account_admins_count) do
    not is_nil(account.limits.account_admin_users_count) and
      account_admins_count > account.limits.account_admin_users_count
  end

  def can_create_admin_users?(%Domain.Account{} = account) do
    account_admins_count = DB.count_account_admin_users_for_account(account)

    Domain.Account.active?(account) and
      (is_nil(account.limits.account_admin_users_count) or
         account_admins_count < account.limits.account_admin_users_count)
  end

  # API wrappers

  def create_customer(%Domain.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    email = get_customer_email(account)

    with {:ok, %{"id" => customer_id, "email" => customer_email}} <-
           APIClient.create_customer(secret_key, account.legal_name, email, %{
             account_id: account.id,
             account_name: account.name,
             account_slug: account.slug
           }) do
      account
      |> update_account_metadata_changeset(%{
        stripe: %{customer_id: customer_id, billing_email: customer_email}
      })
      |> DB.update()
    else
      {:ok, {status, body}} ->
        :ok =
          Logger.error("Cannot create Stripe customer",
            status: status,
            body: inspect(body)
          )

        {:error, :retry_later}

      {:error, reason} ->
        :ok =
          Logger.error("Cannot create Stripe customer",
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  defp get_customer_email(%{metadata: %{stripe: %{billing_email: email}}}), do: email
  defp get_customer_email(_account), do: nil

  def update_stripe_customer(%Domain.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    customer_id = account.metadata.stripe.customer_id

    with {:ok, _customer} <-
           APIClient.update_customer(
             secret_key,
             customer_id,
             account.legal_name,
             %{
               account_id: account.id,
               account_name: account.name,
               account_slug: account.slug
             }
           ) do
      {:ok, account}
    else
      {:error, {status, body}} ->
        :ok =
          Logger.error("Cannot update Stripe customer",
            status: status,
            body: inspect(body)
          )

        {:error, :retry_later}

      {:error, reason} ->
        :ok =
          Logger.error("Cannot update Stripe customer",
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  def fetch_customer_account_id(customer_id) do
    secret_key = fetch_config!(:secret_key)

    with {:ok, %{"metadata" => %{"account_id" => account_id}}} <-
           APIClient.fetch_customer(secret_key, customer_id) do
      {:ok, account_id}
    else
      {:ok, {status, body}} ->
        :ok =
          Logger.error("Cannot fetch Stripe customer",
            status: status,
            body: inspect(body)
          )

        {:error, :retry_later}

      {:ok, params} ->
        :ok =
          Logger.info("Stripe customer does not have account_id in metadata",
            customer_id: customer_id,
            metadata: inspect(params["metadata"])
          )

        {:error, :customer_not_provisioned}

      {:error, reason} ->
        :ok =
          Logger.error("Cannot fetch Stripe customer",
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  def list_all_subscriptions do
    secret_key = fetch_config!(:secret_key)
    APIClient.list_all_subscriptions(secret_key)
  end

  def create_subscription(%Domain.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    default_price_id = fetch_config!(:default_price_id)
    customer_id = account.metadata.stripe.customer_id

    with {:ok, %{"id" => subscription_id}} <-
           APIClient.create_subscription(secret_key, customer_id, default_price_id) do
      account
      |> update_account_metadata_changeset(%{
        stripe: %{subscription_id: subscription_id}
      })
      |> DB.update()
    else
      {:ok, {status, body}} ->
        :ok =
          Logger.error("Cannot create Stripe subscription",
            status: status,
            body: inspect(body)
          )

        {:error, :retry_later}

      {:error, reason} ->
        :ok =
          Logger.error("Cannot create Stripe subscription",
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  def fetch_product(product_id) do
    secret_key = fetch_config!(:secret_key)

    with {:ok, product} <- APIClient.fetch_product(secret_key, product_id) do
      {:ok, product}
    else
      {:error, {status, body}} ->
        :ok =
          Logger.error("Cannot fetch Stripe product",
            status: status,
            body: inspect(body)
          )

        {:error, :retry_later}

      {:error, reason} ->
        :ok =
          Logger.error("Cannot fetch Stripe product",
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  # Account management, sync and provisioning

  def account_provisioned?(%Domain.Account{metadata: %{stripe: %{customer_id: customer_id}}})
      when not is_nil(customer_id) do
    enabled?()
  end

  def account_provisioned?(%Domain.Account{}) do
    false
  end

  def provision_account(%Domain.Account{} = account) do
    with true <- enabled?(),
         true <- not account_provisioned?(account),
         {:ok, account} <- create_customer(account),
         {:ok, account} <- create_subscription(account) do
      {:ok, account}
    else
      false ->
        {:ok, account}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def on_account_name_or_slug_changed(%Domain.Account{} = account) do
    cond do
      not account_provisioned?(account) ->
        :ok

      not enabled?() ->
        :ok

      true ->
        {:ok, _customer} = update_stripe_customer(account)
        :ok
    end
  end

  def billing_portal_url(%Domain.Account{} = account, return_url, %Auth.Subject{} = subject) do
    secret_key = fetch_config!(:secret_key)

    # Only account admins can manage billing
    case subject.actor.type do
      :account_admin_user when subject.account.id == account.id ->
        with {:ok, %{"url" => url}} <-
               APIClient.create_billing_portal_session(
                 secret_key,
                 account.metadata.stripe.customer_id,
                 return_url
               ) do
          {:ok, url}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def handle_events(events) when is_list(events) do
    Enum.each(events, &EventHandler.handle_event/1)
  end

  defp fetch_config!(key) do
    Domain.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(key)
  end

  defp update_account_metadata_changeset(account, stripe_metadata) do
    import Ecto.Changeset

    account
    |> cast(%{metadata: %{stripe: stripe_metadata}}, [])
    |> cast_embed(:metadata,
      with: fn metadata, _params ->
        metadata
        |> cast(%{stripe: stripe_metadata}, [])
        |> cast_embed(:stripe)
      end
    )
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Repo}
    alias Domain.Account
    alias Domain.Actor
    alias Domain.Client

    def update(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    def count_users_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_service_accounts_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type == :service_account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_account_admin_users_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type == :account_admin_user
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_1m_active_users_for_account(%Account{} = account) do
      from(c in Client, as: :clients)
      |> where([clients: c], c.account_id == ^account.id)
      |> where([clients: c], c.last_seen_at > ago(1, "month"))
      |> join(:inner, [clients: c], a in Actor, on: c.actor_id == a.id, as: :actor)
      |> where([actor: a], is_nil(a.disabled_at))
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([clients: c], c.actor_id)
      |> distinct(true)
      |> Repo.aggregate(:count)
    end

    def count_sites_for_account(account) do
      from(g in Domain.Site,
        where: g.account_id == ^account.id,
        where: g.managed_by == :account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end
  end
end
