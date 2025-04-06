defmodule Domain.Billing do
  use Supervisor
  alias Domain.{Auth, Accounts, Actors, Clients, Gateways}
  alias Domain.Billing.{Authorizer, Jobs, EventHandler}
  alias Domain.Billing.Stripe.APIClient
  require Logger

  # Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      APIClient,
      Jobs.CheckAccountLimits
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Configuration helpers

  def fetch_webhook_signing_secret! do
    fetch_config!(:webhook_signing_secret)
  end

  # API wrappers

  def create_customer(%Accounts.Account{} = account, attrs) do
    secret_key = fetch_config!(:secret_key)

    with {:ok, %{"id" => customer_id, "email" => customer_email}} <-
           APIClient.create_customer(secret_key, account.legal_name, email, %{
             account_id: account.id,
             account_name: account.name,
             account_slug: account.slug
           }) do
      Accounts.update_account(account, %{
        metadata: %{
          stripe: %{customer_id: customer_id, billing_email: customer_email}
        }
      })
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

  def update_customer(%Accounts.Account{stripe_customer_id: stripe_customer_id} = account) do
    secret_key = fetch_config!(:secret_key)

    with {:ok, _customer} <-
           APIClient.update_customer(
             secret_key,
             stripe_customer_id,
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
          Logger.warning("Stripe customer does not have account_id in metadata",
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

  def create_subscription(%Accounts.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    default_price_id = fetch_config!(:default_price_id)
    customer_id = account.metadata.stripe.customer_id

    with {:ok, %{"id" => subscription_id}} <-
           APIClient.create_subscription(secret_key, customer_id, default_price_id) do
      Accounts.update_account(account, %{
        metadata: %{stripe: %{subscription_id: subscription_id}}
      })
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

  def fetch_billing_info(%Accounts.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    customer_id = account.stripe_customer_id

    with {:ok, %{"subscriptions" => subscriptions}} <-
           APIClient.fetch_billing_info(secret_key, customer_id) do
      {:ok, subscriptions}
    else
      {:error, {status, body}} ->
        :ok =
          Logger.error("Cannot fetch Stripe billing info",
            status: status,
            body: inspect(body)
          )

        {:error, :retry_later}

      {:error, reason} ->
        :ok =
          Logger.error("Cannot fetch Stripe billing info",
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

  def provision_account(%Accounts.Account{} = account) do
    with {:ok, account} <- create_customer(account),
         {:ok, account} <- create_subscription(account) do
      {:ok, account}
    else
      false ->
        {:ok, account}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def on_account_update(%Accounts.Account{} = account, %Ecto.Changeset{} = changeset) do
    name_changed? = Ecto.Changeset.changed?(changeset, :name)
    slug_changed? = Ecto.Changeset.changed?(changeset, :slug)

    cond do
      not name_changed? and not slug_changed? ->
        :ok

      true ->
        {:ok, _customer} = update_customer(account)
        :ok
    end
  end

  def billing_portal_url(%Accounts.Account{} = account, return_url, %Auth.Subject{} = subject) do
    secret_key = fetch_config!(:secret_key)
    required_permissions = [Authorizer.manage_own_account_billing_permission()]

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         {:ok, %{"url" => url}} <-
           APIClient.create_billing_portal_session(
             secret_key,
             account.metadata.stripe.customer_id,
             return_url
           ) do
      {:ok, url}
    end
  end

  def handle_events(events) when is_list(events) do
    Enum.each(events, &EventHandler.handle_event/1)
  end

  defp fetch_config!(key) do
    Domain.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(key)
  end
end
