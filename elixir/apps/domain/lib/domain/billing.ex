defmodule Domain.Billing do
  use Supervisor
  alias Domain.{Auth, Accounts}
  alias Domain.Billing.Stripe.APIClient
  alias Domain.Billing.Authorizer
  require Logger

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

  def enabled? do
    fetch_config!(:enabled)
  end

  def fetch_webhook_signing_secret! do
    fetch_config!(:webhook_signing_secret)
  end

  def account_provisioned?(%Accounts.Account{metadata: %{stripe: %{customer_id: customer_id}}})
      when not is_nil(customer_id) do
    enabled?()
  end

  def account_provisioned?(_account) do
    false
  end

  def seats_limit_exceeded?(%Accounts.Account{} = account, active_actors_count) do
    Domain.Accounts.account_active?(account) and
      active_actors_count >= account.limits.monthly_active_actors_count
  end

  def provision_account(%Accounts.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    default_price_id = fetch_config!(:default_price_id)

    with true <- enabled?(),
         true <- not account_provisioned?(account),
         {:ok, %{"id" => customer_id}} <-
           APIClient.create_customer(secret_key, account.id, account.name),
         {:ok, %{"id" => subscription_id}} <-
           APIClient.create_subscription(secret_key, customer_id, default_price_id) do
      Accounts.update_account(account, %{
        metadata: %{
          stripe: %{
            customer_id: customer_id,
            subscription_id: subscription_id
          }
        }
      })
    else
      false ->
        {:ok, account}

      {:ok, {status, body}} ->
        :ok = Logger.error("Stripe API call failed", status: status, body: inspect(body))
        {:error, :retry_later}

      {:error, reason} ->
        :ok = Logger.error("Stripe API call failed", reason: inspect(reason))
        {:error, :retry_later}
    end
  end

  def billing_portal_url(%Accounts.Account{} = account, return_url, %Auth.Subject{} = subject) do
    secret_key = fetch_config!(:secret_key)

    with :ok <-
           Auth.ensure_has_permissions(
             subject,
             Authorizer.manage_own_account_billing_permission()
           ),
         true <- account_provisioned?(account),
         {:ok, %{"url" => url}} <-
           APIClient.create_billing_portal_session(
             secret_key,
             account.metadata.stripe.customer_id,
             return_url
           ) do
      {:ok, url}
    else
      false -> {:error, :account_not_provisioned}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_events(events) when is_list(events) do
    Enum.each(events, &handle_event/1)
  end

  # subscription is ended or deleted
  defp handle_event(%{
         "object" => "event",
         "data" => %{
           "object" => %{
             "customer" => customer_id
           }
         },
         "type" => "customer.subscription.deleted"
       }) do
    update_account_by_stripe_customer_id(customer_id, %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription deleted"
    })
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  # subscription is paused
  defp handle_event(%{
         "object" => "event",
         "data" => %{
           "object" => %{
             "customer" => customer_id,
             "pause_collection" => %{
               "behavior" => "void"
             }
           }
         },
         "type" => "customer.subscription.updated"
       }) do
    update_account_by_stripe_customer_id(customer_id, %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription paused"
    })
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  defp handle_event(%{
         "object" => "event",
         "data" => %{
           "object" => %{
             "customer" => customer_id
           }
         },
         "type" => "customer.subscription.paused"
       }) do
    update_account_by_stripe_customer_id(customer_id, %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription paused"
    })
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  # subscription is resumed, created or updated
  defp handle_event(%{
         "object" => "event",
         "data" => %{
           "object" => %{
             "id" => subscription_id,
             "customer" => customer_id,
             "metadata" => subscription_metadata,
             "items" => %{
               "data" => [
                 %{
                   "plan" => %{
                     "product" => product_id
                   },
                   "quantity" => quantity
                 }
               ]
             }
           }
         },
         "type" => "customer.subscription." <> _
       }) do
    secret_key = fetch_config!(:secret_key)

    {:ok, %{"name" => product_name, "metadata" => product_metadata}} =
      APIClient.fetch_product(secret_key, product_id)

    attrs =
      account_update_attrs(quantity, product_metadata, subscription_metadata)
      |> Map.put(:metadata, %{
        stripe: %{
          subscription_id: subscription_id,
          product_name: product_name
        }
      })
      |> Map.put(:disabled_at, nil)
      |> Map.put(:disabled_reason, nil)

    update_account_by_stripe_customer_id(customer_id, attrs)
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  defp handle_event(%{"object" => "event", "data" => %{}}) do
    :ok
  end

  defp update_account_by_stripe_customer_id(customer_id, attrs) do
    secret_key = fetch_config!(:secret_key)

    with {:ok, %{"metadata" => %{"account_id" => account_id}}} <-
           APIClient.fetch_customer(secret_key, customer_id) do
      Accounts.update_account_by_id(account_id, attrs)
    else
      {:ok, params} ->
        :ok =
          Logger.error("Stripe customer does not have account_id in metadata",
            metadata: inspect(params["metadata"])
          )

        {:error, :retry_later}

      {:ok, {status, body}} ->
        :ok = Logger.error("Can not fetch Stripe customer", status: status, body: inspect(body))
        {:error, :retry_later}

      {:error, reason} ->
        :ok = Logger.error("Can not fetch Stripe customer", reason: inspect(reason))
        {:error, :retry_later}
    end
  end

  defp account_update_attrs(quantity, product_metadata, subscription_metadata) do
    features_and_limits =
      Map.merge(product_metadata, subscription_metadata)
      |> Enum.flat_map(fn
        {feature, "true"} ->
          [{feature, true}]

        {feature, "false"} ->
          [{feature, false}]

        {"monthly_active_actors_count", count} ->
          [{"monthly_active_actors_count", String.to_integer(count)}]

        {_key, _value} ->
          []
      end)
      |> Enum.into(%{})

    {monthly_active_actors_count, features} =
      Map.pop(features_and_limits, "monthly_active_actors_count", quantity)

    %{
      features: features,
      limits: %{monthly_active_actors_count: monthly_active_actors_count}
    }
  end

  defp fetch_config!(key) do
    Domain.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(key)
  end
end
