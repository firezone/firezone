defmodule Portal.Billing do
  alias Portal.Authentication
  alias Portal.Billing.EventHandler
  alias Portal.Billing.Stripe.APIClient
  alias __MODULE__.Database
  require Logger

  @invoice_terms_days 30

  # Configuration helpers

  def enabled? do
    fetch_config!(:enabled)
  end

  def fetch_webhook_signing_secret! do
    fetch_config!(:webhook_signing_secret)
  end

  def plan_product_ids do
    fetch_config!(:plan_product_ids)
  end

  def adhoc_device_product_id do
    fetch_config!(:adhoc_device_product_id)
  end

  # Limits and Features

  @doc """
  Returns true if any billing limit is exceeded.
  """
  @spec any_limit_exceeded?(Portal.Account.t()) :: boolean()
  def any_limit_exceeded?(%Portal.Account{} = account) do
    account.users_limit_exceeded or
      account.seats_limit_exceeded or
      account.service_accounts_limit_exceeded or
      account.sites_limit_exceeded or
      account.admins_limit_exceeded
  end

  @doc """
  Builds a human-readable warning message from the exceeded limit flags.
  Returns nil if no limits are exceeded.

  When counts are provided, displays each exceeded limit in the format:
  "label (count / limit)"
  """
  @spec build_limits_exceeded_message(Portal.Account.t(), map()) :: String.t() | nil
  def build_limits_exceeded_message(%Portal.Account{} = account, counts \\ %{}) do
    limits =
      []
      |> maybe_add_with_counts(
        "users",
        account.users_limit_exceeded,
        counts[:users],
        account.limits && account.limits.users_count
      )
      |> maybe_add_with_counts(
        "monthly active users",
        account.seats_limit_exceeded,
        counts[:active_users],
        account.limits && account.limits.monthly_active_users_count
      )
      |> maybe_add_with_counts(
        "service accounts",
        account.service_accounts_limit_exceeded,
        counts[:service_accounts],
        account.limits && account.limits.service_accounts_count
      )
      |> maybe_add_with_counts(
        "sites",
        account.sites_limit_exceeded,
        counts[:sites],
        account.limits && account.limits.sites_count
      )
      |> maybe_add_with_counts(
        "account admins",
        account.admins_limit_exceeded,
        counts[:admins],
        account.limits && account.limits.account_admin_users_count
      )

    case limits do
      [] -> nil
      limits -> Enum.join(limits, "\n")
    end
  end

  defp maybe_add_with_counts(list, label, true, count, limit)
       when is_integer(count) and is_integer(limit) do
    list ++ ["#{label} (#{count} / #{limit})"]
  end

  defp maybe_add_with_counts(list, label, true, _count, _limit) do
    list ++ [label]
  end

  defp maybe_add_with_counts(list, _label, false, _count, _limit), do: list

  @doc """
  Returns the plan type for the account based on the Stripe product name.
  Returns :enterprise, :team, :starter, or :unknown.
  """
  @spec plan_type(Portal.Account.t() | String.t() | nil) ::
          :enterprise | :team | :starter | :unknown
  def plan_type(%Portal.Account{metadata: %{stripe: %{product_name: product_name}}}),
    do: plan_type(product_name)

  def plan_type(%Portal.Account{}), do: :unknown

  def plan_type(product_name) when is_binary(product_name) do
    cond do
      String.starts_with?(product_name, "Enterprise") -> :enterprise
      product_name == "Team" -> :team
      product_name == "Starter" -> :starter
      true -> :unknown
    end
  end

  def plan_type(nil), do: :unknown

  @spec paid_plan?(Portal.Account.t()) :: boolean()
  def paid_plan?(%Portal.Account{} = account), do: plan_type(account) in [:team, :enterprise]

  def users_limit_exceeded?(%Portal.Account{} = account, users_count) do
    not is_nil(account.limits.users_count) and
      users_count > account.limits.users_count
  end

  def seats_limit_exceeded?(%Portal.Account{} = account, active_users_count) do
    not is_nil(account.limits.monthly_active_users_count) and
      active_users_count > account.limits.monthly_active_users_count
  end

  def can_create_users?(%Portal.Account{} = account) do
    users_count = Database.count_users_for_account(account)
    active_users_count = Database.count_1m_active_users_for_account(account)

    cond do
      not Portal.Account.active?(account) ->
        false

      not is_nil(account.limits.monthly_active_users_count) ->
        active_users_count < account.limits.monthly_active_users_count

      not is_nil(account.limits.users_count) ->
        users_count < account.limits.users_count

      true ->
        true
    end
  end

  def service_accounts_limit_exceeded?(%Portal.Account{} = account, service_accounts_count) do
    not is_nil(account.limits.service_accounts_count) and
      service_accounts_count > account.limits.service_accounts_count
  end

  def can_create_service_accounts?(%Portal.Account{} = account) do
    service_accounts_count = Database.count_service_accounts_for_account(account)

    Portal.Account.active?(account) and
      (is_nil(account.limits.service_accounts_count) or
         service_accounts_count < account.limits.service_accounts_count)
  end

  def sites_limit_exceeded?(%Portal.Account{} = account, sites_count) do
    not is_nil(account.limits.sites_count) and
      sites_count > account.limits.sites_count
  end

  def can_create_sites?(%Portal.Account{} = account) do
    sites_count = Database.count_sites_for_account(account)

    Portal.Account.active?(account) and
      (is_nil(account.limits.sites_count) or
         sites_count < account.limits.sites_count)
  end

  def admins_limit_exceeded?(%Portal.Account{} = account, account_admins_count) do
    not is_nil(account.limits.account_admin_users_count) and
      account_admins_count > account.limits.account_admin_users_count
  end

  def can_create_admin_users?(%Portal.Account{} = account) do
    account_admins_count = Database.count_account_admin_users_for_account(account)

    Portal.Account.active?(account) and
      (is_nil(account.limits.account_admin_users_count) or
         account_admins_count < account.limits.account_admin_users_count)
  end

  def api_clients_limit_exceeded?(%Portal.Account{} = account, api_clients_count) do
    not is_nil(account.limits.api_clients_count) and
      api_clients_count > account.limits.api_clients_count
  end

  def can_create_api_clients?(%Portal.Account{} = account) do
    api_clients_count = Database.count_api_clients_for_account(account)

    Portal.Account.active?(account) and
      (is_nil(account.limits.api_clients_count) or
         api_clients_count < account.limits.api_clients_count)
  end

  @type actor_enable_limit_error ::
          :users_limit_reached
          | :admin_users_limit_reached
          | :service_accounts_limit_reached
          | :api_clients_limit_reached

  @doc """
  Checks whether an actor can be enabled without exceeding its account's billing limits.
  """
  @spec check_actor_enable_limits(Portal.Account.t(), Portal.Actor.t()) ::
          :ok | {:error, actor_enable_limit_error()}
  def check_actor_enable_limits(%Portal.Account{} = account, %Portal.Actor{
        type: :account_admin_user
      }) do
    cond do
      not can_create_users?(account) ->
        {:error, :users_limit_reached}

      not can_create_admin_users?(account) ->
        {:error, :admin_users_limit_reached}

      true ->
        :ok
    end
  end

  def check_actor_enable_limits(%Portal.Account{} = account, %Portal.Actor{
        type: :account_user
      }) do
    if can_create_users?(account), do: :ok, else: {:error, :users_limit_reached}
  end

  def check_actor_enable_limits(%Portal.Account{} = account, %Portal.Actor{
        type: :service_account
      }) do
    if can_create_service_accounts?(account),
      do: :ok,
      else: {:error, :service_accounts_limit_reached}
  end

  def check_actor_enable_limits(%Portal.Account{} = account, %Portal.Actor{type: :api_client}) do
    if can_create_api_clients?(account), do: :ok, else: {:error, :api_clients_limit_reached}
  end

  def api_tokens_limit_exceeded?(%Portal.Account{} = account, api_tokens_count) do
    not is_nil(account.limits.api_tokens_per_client_count) and
      api_tokens_count > account.limits.api_tokens_per_client_count
  end

  def can_create_api_tokens?(%Portal.Account{} = account, %Portal.Actor{} = actor) do
    api_tokens_count = Database.count_api_tokens_for_actor(actor)

    Portal.Account.active?(account) and
      (is_nil(account.limits.api_tokens_per_client_count) or
         api_tokens_count < account.limits.api_tokens_per_client_count)
  end

  @doc """
  Checks if a UI client sign-in should be blocked for the given account.

  Returns `true` if sign-in should be blocked (users limit exceeded),
  `false` otherwise.

  Note: seats_limit_exceeded is a soft limit - it doesn't block sign-ins.
  A warning is logged by CheckAccountLimits worker when first exceeded.
  """
  @spec client_sign_in_restricted?(Portal.Account.t()) :: boolean()
  def client_sign_in_restricted?(%Portal.Account{} = account) do
    account.users_limit_exceeded
  end

  @doc """
  Checks if an API client connection should be blocked for the given account.

  Returns `true` if connection should be blocked (users or service accounts
  limits exceeded), `false` otherwise.

  Note: seats_limit_exceeded is a soft limit - it doesn't block connections.
  A warning is logged by CheckAccountLimits worker when first exceeded.
  """
  @spec client_connect_restricted?(Portal.Account.t()) :: boolean()
  def client_connect_restricted?(%Portal.Account{} = account) do
    account.users_limit_exceeded or account.service_accounts_limit_exceeded
  end

  @doc """
  Evaluates account limits and updates the limit exceeded flags accordingly.

  This should be called after subscription updates to immediately reflect
  any changes in limits (e.g., when seats are added/removed).
  """
  @spec evaluate_account_limits(Portal.Account.t()) ::
          {:ok, Portal.Account.t()} | {:error, term()}
  def evaluate_account_limits(%Portal.Account{} = account) do
    if account_provisioned?(account) do
      limit_flags = %{
        users_limit_exceeded:
          users_limit_exceeded?(account, Database.count_users_for_account(account)),
        seats_limit_exceeded:
          seats_limit_exceeded?(account, Database.count_1m_active_users_for_account(account)),
        service_accounts_limit_exceeded:
          service_accounts_limit_exceeded?(
            account,
            Database.count_service_accounts_for_account(account)
          ),
        sites_limit_exceeded:
          sites_limit_exceeded?(account, Database.count_sites_for_account(account)),
        admins_limit_exceeded:
          admins_limit_exceeded?(account, Database.count_account_admin_users_for_account(account))
      }

      Database.update_account_limit_flags(account, limit_flags)
    else
      {:ok, account}
    end
  end

  # API wrappers

  def create_customer(%Portal.Account{} = account) do
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
        customer_id: customer_id,
        billing_email: customer_email
      })
      |> Database.update()
    else
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

  def update_stripe_customer(%Portal.Account{} = account) do
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

  @doc """
  Cancels all Stripe subscriptions for the given Stripe customer ID.
  Use when the account record is no longer available (e.g. after deletion).
  """
  @spec cancel_subscriptions_by_customer_id(String.t()) :: :ok | {:error, :retry_later}
  def cancel_subscriptions_by_customer_id(customer_id) do
    if enabled?() do
      do_cancel_subscriptions(customer_id)
    else
      :ok
    end
  end

  defp do_cancel_subscriptions(customer_id) do
    secret_key = fetch_config!(:secret_key)

    case APIClient.fetch_customer_subscriptions(secret_key, customer_id) do
      {:ok, %{"data" => subscriptions}} ->
        Enum.reduce_while(subscriptions, :ok, fn %{"id" => subscription_id}, :ok ->
          cancel_subscription_by_id(secret_key, customer_id, subscription_id)
        end)

      {:error, reason} ->
        Logger.error("Cannot fetch Stripe subscriptions for customer",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, :retry_later}
    end
  end

  def list_all_subscriptions do
    secret_key = fetch_config!(:secret_key)
    APIClient.list_all_subscriptions(secret_key)
  end

  defp cancel_subscription_by_id(secret_key, customer_id, subscription_id) do
    case APIClient.cancel_subscription(secret_key, subscription_id) do
      {:ok, _} ->
        {:cont, :ok}

      {:error, {404, _}} ->
        {:cont, :ok}

      {:error, reason} ->
        Logger.error("Cannot cancel Stripe subscription",
          customer_id: customer_id,
          subscription_id: subscription_id,
          reason: inspect(reason)
        )

        {:halt, {:error, :retry_later}}
    end
  end

  def create_subscription(%Portal.Account{} = account) do
    secret_key = fetch_config!(:secret_key)
    default_price_id = fetch_config!(:default_price_id)
    customer_id = account.metadata.stripe.customer_id

    with {:ok, %{"id" => subscription_id}} <-
           APIClient.create_subscription(secret_key, customer_id, default_price_id) do
      account
      |> update_account_metadata_changeset(%{subscription_id: subscription_id})
      |> Database.update()
    else
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

  def account_provisioned?(%Portal.Account{metadata: %{stripe: %{customer_id: customer_id}}})
      when not is_nil(customer_id) do
    enabled?()
  end

  def account_provisioned?(%Portal.Account{}) do
    false
  end

  defp ensure_internet_site_and_resource_exist(%Portal.Account{} = account) do
    # Ensure Internet site exists
    site =
      case Database.fetch_internet_site(account) do
        {:ok, site} ->
          site

        {:error, :not_found} ->
          {:ok, site} = Database.create_internet_site(account)
          site
      end

    # Ensure Internet resource exists
    case Database.fetch_internet_resource(account) do
      {:ok, _resource} ->
        {:ok, account}

      {:error, :not_found} ->
        {:ok, _resource} = Database.create_internet_resource(account, site)
        {:ok, account}
    end
  end

  @doc """
  Provisions a Stripe customer and subscription for a new account before it is
  created in the database. Called during sign-up so that Stripe failures are
  detected upfront rather than inside a database transaction.

  Returns `{:ok, stripe_info}` on success (map with customer_id, billing_email,
  and subscription_id), `{:ok, nil}` when billing is disabled, or
  `{:error, :retry_later}` on Stripe failure.
  """
  @spec provision_stripe_for_signup(String.t(), String.t(), String.t()) ::
          {:ok, map() | nil} | {:error, :retry_later}
  def provision_stripe_for_signup(account_id, legal_name, email) do
    if enabled?() do
      secret_key = fetch_config!(:secret_key)
      default_price_id = fetch_config!(:default_price_id)

      with {:ok, %{"id" => customer_id, "email" => billing_email}} <-
             APIClient.create_customer(secret_key, legal_name, email, %{
               account_id: account_id,
               account_name: legal_name
             }),
           {:ok, %{"id" => subscription_id}} <-
             APIClient.create_subscription(secret_key, customer_id, default_price_id) do
        {:ok,
         %{
           customer_id: customer_id,
           billing_email: billing_email,
           subscription_id: subscription_id
         }}
      else
        {:error, reason} ->
          :ok =
            Logger.error("Cannot provision Stripe account for signup",
              reason: inspect(reason)
            )

          {:error, :retry_later}
      end
    else
      {:ok, nil}
    end
  end

  def provision_account(%Portal.Account{} = account) do
    with true <- enabled?(),
         true <- not account_provisioned?(account),
         {:ok, account} <- ensure_internet_site_and_resource_exist(account),
         {:ok, account} <- create_customer(account),
         {:ok, account} <- create_subscription(account) do
      {:ok, account}
    else
      false ->
        ensure_internet_site_and_resource_exist(account)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def on_account_name_or_slug_changed(%Portal.Account{} = account) do
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

  def billing_portal_url(
        %Portal.Account{} = account,
        return_url,
        %Authentication.Subject{} = subject
      ) do
    # Only account admins can manage billing
    case subject.actor.type do
      :account_admin_user when subject.account.id == account.id ->
        create_billing_portal_session(account, return_url)

      _ ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Finds the subscription item that carries the plan the account is on.
  """
  @spec fetch_plan_item([map()]) ::
          {:ok, map()}
          | {:error, :no_plan_product | :no_plan_quantity | :multiple_plan_products}
  def fetch_plan_item(items) do
    {plan_items, other_items} =
      Enum.split_with(items, &(get_in(&1, ["price", "product"]) in plan_product_ids()))

    log_non_plan_items(other_items)

    case plan_items do
      [%{"quantity" => quantity} = item] when is_integer(quantity) ->
        {:ok, item}

      [item] ->
        Logger.error("Plan product has no seat quantity", item_id: item["id"])
        {:error, :no_plan_quantity}

      [] ->
        {:error, :no_plan_product}

      multiple ->
        ids = Enum.map(multiple, &get_in(&1, ["price", "product"]))
        Logger.error("Multiple plan products found in subscription", product_ids: inspect(ids))
        {:error, :multiple_plan_products}
    end
  end

  @doc """
  Moves the seat floor of the account's billing portal configuration to the
  quantity Stripe is now billing, so that seats added through the portal cannot
  be given back through the portal.

  Called after a subscription change. Best effort: the configuration is rebuilt
  from the subscription anyway the next time the portal is opened.
  """
  @spec sync_billing_portal_configuration(Portal.Account.t(), map()) :: :ok
  def sync_billing_portal_configuration(%Portal.Account{} = account, subscription_data) do
    configuration_id = account.metadata.stripe.portal_configuration_id

    if plan_type(account) == :enterprise and is_binary(configuration_id) do
      items = get_in(subscription_data, ["items", "data"]) || []

      with {:ok, item} <- fetch_plan_item(items),
           {:ok, _configuration_id} <- update_portal_configuration(account, configuration_id, item) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("Cannot sync Stripe billing portal configuration",
            account_id: account.id,
            reason: inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Serializes work for a Stripe customer across the cluster.
  """
  def with_customer_lock(customer_id, fun) do
    Database.with_customer_lock(customer_id, fun)
  end

  defp create_billing_portal_session(%Portal.Account{} = account, return_url) do
    secret_key = fetch_config!(:secret_key)

    with {:ok, configuration_id} <- billing_portal_configuration_id(account),
         {:ok, %{"url" => url}} <-
           APIClient.create_billing_portal_session(
             secret_key,
             account.metadata.stripe.customer_id,
             return_url,
             configuration_id
           ) do
      {:ok, url}
    end
  end

  # Starter and Team accounts use the default configuration managed from the
  # Stripe dashboard. Enterprise accounts get one of their own, rebuilt on every
  # visit, that only lets them buy more seats.
  defp billing_portal_configuration_id(%Portal.Account{} = account) do
    if plan_type(account) == :enterprise do
      put_enterprise_portal_configuration(account)
    else
      {:ok, nil}
    end
  end

  defp put_enterprise_portal_configuration(%Portal.Account{} = account) do
    with_customer_lock(account.metadata.stripe.customer_id, fn ->
      account = Database.fetch_account_by_id!(account.id)

      with {:ok, subscription} <- fetch_subscription(account),
           {:ok, item} <- fetch_plan_item(get_in(subscription, ["items", "data"]) || []) do
        :ok = warn_unless_net30(account, subscription)
        put_portal_configuration(account, item)
      end
    end)
  end

  defp put_portal_configuration(%Portal.Account{} = account, item) do
    case account.metadata.stripe.portal_configuration_id do
      nil ->
        create_portal_configuration(account, item)

      configuration_id ->
        update_portal_configuration(account, configuration_id, item)
    end
  end

  defp fetch_subscription(%Portal.Account{} = account) do
    secret_key = fetch_config!(:secret_key)

    case account.metadata.stripe.subscription_id do
      nil ->
        Logger.error("Account has no Stripe subscription", account_id: account.id)
        {:error, :no_subscription}

      subscription_id ->
        APIClient.fetch_subscription(secret_key, subscription_id)
    end
  end

  # Stripe copies the payment terms from the subscription onto the invoice it
  # raises for the extra seats, and there is no way to set them per invoice.
  defp warn_unless_net30(%Portal.Account{} = account, subscription) do
    collection_method = subscription["collection_method"]
    days_until_due = subscription["days_until_due"]

    if collection_method != "send_invoice" or days_until_due != @invoice_terms_days do
      Logger.warning("Enterprise subscription does not invoice seats on the expected terms",
        account_id: account.id,
        collection_method: collection_method,
        days_until_due: days_until_due,
        expected_days_until_due: @invoice_terms_days
      )
    end

    :ok
  end

  defp create_portal_configuration(%Portal.Account{} = account, item) do
    secret_key = fetch_config!(:secret_key)
    params = portal_configuration_params(account, item)

    with {:ok, %{"id" => configuration_id}} <-
           APIClient.create_billing_portal_configuration(secret_key, params),
         {:ok, _account} <-
           account
           |> update_account_metadata_changeset(%{portal_configuration_id: configuration_id})
           |> Database.update() do
      {:ok, configuration_id}
    else
      {:error, reason} ->
        :ok =
          Logger.error("Cannot create Stripe billing portal configuration",
            account_id: account.id,
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  defp update_portal_configuration(%Portal.Account{} = account, configuration_id, item) do
    secret_key = fetch_config!(:secret_key)
    params = portal_configuration_params(account, item)

    case APIClient.update_billing_portal_configuration(secret_key, configuration_id, params) do
      {:ok, %{"id" => configuration_id}} ->
        {:ok, configuration_id}

      # The stored configuration is gone, e.g. because the Stripe account changed.
      {:error, {404, _body}} ->
        create_portal_configuration(account, item)

      {:error, reason} ->
        :ok =
          Logger.error("Cannot update Stripe billing portal configuration",
            account_id: account.id,
            configuration_id: configuration_id,
            reason: inspect(reason)
          )

        {:error, :retry_later}
    end
  end

  # The floor tracks the billed quantity in both directions: only the customer's
  # self-serve path is restricted, so seats we take away for them stay removed.
  defp portal_configuration_params(%Portal.Account{} = account, item) do
    %{
      "metadata[account_id]" => account.id,
      "features[customer_update][enabled]" => "true",
      "features[customer_update][allowed_updates][0]" => "address",
      "features[customer_update][allowed_updates][1]" => "email",
      "features[customer_update][allowed_updates][2]" => "name",
      "features[customer_update][allowed_updates][3]" => "phone",
      "features[customer_update][allowed_updates][4]" => "tax_id",
      "features[invoice_history][enabled]" => "true",
      "features[payment_method_update][enabled]" => "true",
      "features[subscription_cancel][enabled]" => "false",
      "features[subscription_update][enabled]" => "true",
      "features[subscription_update][default_allowed_updates][0]" => "quantity",
      "features[subscription_update][proration_behavior]" => "always_invoice",
      "features[subscription_update][products][0][product]" =>
        get_in(item, ["price", "product"]),
      "features[subscription_update][products][0][prices][0]" => get_in(item, ["price", "id"]),
      "features[subscription_update][products][0][adjustable_quantity][enabled]" => "true",
      "features[subscription_update][products][0][adjustable_quantity][minimum]" => item["quantity"]
    }
  end

  defp log_non_plan_items(items) do
    adhoc_id = adhoc_device_product_id()

    Enum.each(items, fn %{"price" => %{"product" => product_id}} = item ->
      if product_id == adhoc_id do
        Logger.info("Ignoring adhoc device product in subscription",
          product_id: product_id,
          item_id: item["id"]
        )
      else
        Logger.warning("Ignoring unrecognized product in subscription",
          product_id: product_id,
          item_id: item["id"]
        )
      end
    end)
  end

  def handle_events(events) when is_list(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case EventHandler.handle_event(event) do
        {:ok, _event} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_config!(key) do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(key)
  end

  defp update_account_metadata_changeset(account, stripe_metadata) do
    import Ecto.Changeset

    # Merge new stripe metadata with existing metadata
    existing_stripe =
      case account.metadata do
        %{stripe: stripe} when not is_nil(stripe) -> Map.from_struct(stripe)
        _ -> %{}
      end

    merged_stripe = Map.merge(existing_stripe, stripe_metadata)

    account
    |> change()
    |> put_change(:metadata, %{stripe: merged_stripe})
    |> cast_embed(:metadata)
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Actor
    alias Portal.Device

    def with_customer_lock(customer_id, fun) do
      hashed_id = :erlang.phash2(customer_id)

      Safe.transact(fn ->
        {:ok, _} = Safe.unscoped() |> Safe.query("SELECT pg_advisory_xact_lock($1)", [hashed_id])
        fun.()
      end)
    end

    def fetch_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def update(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    def update_account_limit_flags(%Account{} = account, attrs) do
      fields = [
        :users_limit_exceeded,
        :seats_limit_exceeded,
        :service_accounts_limit_exceeded,
        :sites_limit_exceeded,
        :admins_limit_exceeded
      ]

      account
      |> cast(attrs, fields)
      |> Safe.unscoped()
      |> Safe.update()
    end

    def count_users_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_service_accounts_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type == :service_account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_account_admin_users_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type == :account_admin_user
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_1m_active_users_for_account(%Account{} = account) do
      from(c in Device, as: :clients)
      |> where([clients: c], c.type == :client)
      |> where([clients: c], c.account_id == ^account.id)
      |> where([clients: c], c.last_seen_at > ago(1, "month"))
      |> join(:inner, [clients: c], a in Actor,
        on: c.actor_id == a.id and c.account_id == a.account_id,
        as: :actor
      )
      |> where([actor: a], a.is_disabled == false)
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([clients: c], c.actor_id)
      |> distinct(true)
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_sites_for_account(account) do
      from(g in Portal.Site,
        where: g.account_id == ^account.id,
        where: g.managed_by == :account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_api_clients_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type == :api_client
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_api_tokens_for_actor(%Actor{} = actor) do
      from(t in Portal.APIToken,
        where: t.actor_id == ^actor.id,
        where: t.account_id == ^actor.account_id
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def fetch_internet_site(%Account{} = account) do
      result =
        from(s in Portal.Site,
          where: s.account_id == ^account.id,
          where: s.name == "Internet",
          where: s.managed_by == :system
        )
        |> Safe.unscoped()
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        site -> {:ok, site}
      end
    end

    def create_internet_site(%Account{} = account) do
      %Portal.Site{
        account_id: account.id,
        name: "Internet",
        managed_by: :system
      }
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def fetch_internet_resource(%Account{} = account) do
      result =
        from(r in Portal.Resource,
          where: r.account_id == ^account.id,
          where: r.type == :internet
        )
        |> Safe.unscoped()
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        resource -> {:ok, resource}
      end
    end

    def create_internet_resource(%Account{} = account, %Portal.Site{} = site) do
      %Portal.Resource{
        account_id: account.id,
        name: "Internet",
        type: :internet,
        site_id: site.id
      }
      |> Safe.unscoped()
      |> Safe.insert()
    end
  end
end
