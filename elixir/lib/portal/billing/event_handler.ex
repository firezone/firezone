defmodule Portal.Billing.EventHandler do
  @moduledoc """
  Handles Stripe webhook events for billing and subscription management.
  """

  alias Portal.Accounts
  alias Portal.Billing
  alias Portal.Billing.Stripe.ProcessedEvents
  alias __MODULE__.DB
  require Logger

  @subscription_events ["created", "resumed"]

  def handle_event(%{"object" => "event"} = event) do
    process_event_with_lock(event)
  end

  defp process_event_with_lock(event) do
    customer_id = extract_customer_id(event)

    DB.with_customer_lock(customer_id, fn ->
      process_event(event, customer_id)
    end)
  end

  defp process_event(event, customer_id) do
    with :ok <- check_event_processing_eligibility(event, customer_id),
         :ok <- process_event_by_type(event),
         :ok <- record_processed_event(event, customer_id) do
      {:ok, event}
    else
      {:skip, reason} ->
        Logger.info("Skipping stripe event", reason: inspect(reason))
        {:ok, event}

      {:error, reason} ->
        Logger.error("Failed to process stripe event",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp check_event_processing_eligibility(event, customer_id) do
    %{
      "id" => event_id,
      "created" => event_created,
      "type" => event_type
    } = event

    if ProcessedEvents.event_processed?(event_id) do
      {:skip, :already_processed}
    else
      check_chronological_order(customer_id, event_created, event_type, event_id)
    end
  end

  defp check_chronological_order(nil, _event_created, _event_type, _event_id) do
    {:skip, :no_customer_id}
  end

  defp check_chronological_order(customer_id, event_created, event_type, event_id) do
    case ProcessedEvents.get_latest_for_stripe_customer(customer_id, event_type) do
      nil ->
        :ok

      latest_event ->
        event_created_at = DateTime.from_unix!(event_created)

        case DateTime.compare(event_created_at, latest_event.event_created_at) do
          :gt ->
            :ok

          _ ->
            Logger.info("Skipping older event",
              event_id: event_id,
              event_created: event_created,
              latest_processed_created: latest_event.event_created_at,
              customer_id: customer_id
            )

            {:skip, :old_event}
        end
    end
  end

  defp extract_customer_id(%{"data" => %{"object" => object}} = event) when is_map(event) do
    case Map.get(object, "object") do
      "customer" -> Map.get(object, "id")
      _ -> Map.get(object, "customer")
    end
  end

  defp process_event_by_type(event) do
    event_type = Map.get(event, "type")
    event_data = get_in(event, ["data", "object"])

    case event_type do
      "customer.created" ->
        handle_customer_created(event_data)

      "customer.updated" ->
        handle_customer_updated(event_data)

      "customer.subscription.deleted" ->
        handle_subscription_deleted(event_data)

      # This event only sent after a Stripe trial has ended
      "customer.subscription.paused" ->
        handle_subscription_paused(event_data)

      "customer.subscription.updated" ->
        handle_subscription_updated(event_data)

      "customer.subscription." <> sub_event when sub_event in @subscription_events ->
        handle_subscription_active(event_data)

      _ ->
        handle_unknown_event(event_type, event_data)
    end
  end

  defp record_processed_event(event, customer_id) do
    event_id = Map.get(event, "id")

    attrs = %{
      stripe_event_id: event_id,
      event_type: Map.get(event, "type"),
      processed_at: DateTime.utc_now(),
      stripe_customer_id: customer_id,
      event_created_at: DateTime.from_unix!(Map.get(event, "created")),
      livemode: Map.get(event, "livemode", false),
      request_id: Map.get(event, "request")
    }

    case ProcessedEvents.create_processed_event(attrs) do
      {:ok, _processed_event} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to record processed stripe event",
          event_id: event_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Customer Events
  defp handle_customer_created(customer_data) do
    create_account_from_stripe_customer(customer_data)
  end

  defp handle_customer_updated(customer_data) do
    %{
      "id" => customer_id,
      "name" => customer_name,
      "email" => customer_email,
      "metadata" => customer_metadata
    } = customer_data

    attrs = build_customer_update_attrs(customer_metadata, customer_name, customer_email)

    case update_account_by_stripe_customer_id(customer_id, attrs) do
      {:ok, _account} ->
        :ok

      {:error, :customer_not_provisioned} ->
        create_account_from_stripe_customer(customer_data)

      {:error, reason} ->
        Logger.error("Failed to sync account from Stripe",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  def handle_customer_deleted(customer_data) do
    %{"id" => customer_id} = customer_data

    disable_account_attrs = %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe customer deleted"
    }

    update_account(customer_id, disable_account_attrs)
  end

  # Subscription Events
  defp handle_subscription_deleted(subscription_data) do
    customer_id = Map.get(subscription_data, "customer")

    disable_account_attrs = %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription deleted"
    }

    update_account(customer_id, disable_account_attrs)
  end

  defp handle_subscription_paused(subscription_data) do
    customer_id = Map.get(subscription_data, "customer")

    disable_account_attrs = %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription paused"
    }

    update_account(customer_id, disable_account_attrs)
  end

  defp handle_subscription_updated(subscription_data) do
    case get_in(subscription_data, ["pause_collection", "behavior"]) do
      "void" ->
        # paused subscription
        handle_subscription_paused(subscription_data)

      _ ->
        # regular subscription update
        handle_subscription_active(subscription_data)
    end
  end

  defp handle_subscription_active(subscription_data) do
    customer_id = Map.get(subscription_data, "customer")

    with {:ok, attrs} <- build_subscription_update_attrs(subscription_data) do
      update_account(customer_id, attrs)
    else
      {:error, reason} ->
        Logger.error("Failed to build subscription update attrs",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # We don't care about any other type of stripe events at this point
  defp handle_unknown_event(_event_type, _event_data), do: :ok

  defp build_customer_update_attrs(customer_metadata, customer_name, customer_email) do
    %{
      name: customer_metadata["account_name"] || customer_name,
      legal_name: customer_name,
      metadata: %{stripe: %{billing_email: customer_email}}
    }
    |> put_if_not_nil(:slug, customer_metadata["account_slug"])
  end

  defp build_subscription_update_attrs(subscription_data) do
    %{
      "id" => subscription_id,
      "customer" => _customer_id,
      "metadata" => subscription_metadata,
      "trial_end" => trial_end,
      "status" => status,
      "items" => %{"data" => [%{"price" => %{"product" => product_id}, "quantity" => quantity}]}
    } = subscription_data

    with {:ok, product_info} <- Billing.fetch_product(product_id) do
      %{"name" => product_name, "metadata" => product_metadata} = product_info

      subscription_trialing? = not is_nil(trial_end) and status in ["trialing", "paused"]

      stripe_metadata = %{
        "subscription_id" => subscription_id,
        "product_name" => product_name,
        "trial_ends_at" => if(subscription_trialing?, do: DateTime.from_unix!(trial_end))
      }

      attrs =
        account_update_attrs(
          quantity,
          product_metadata,
          subscription_metadata,
          stripe_metadata
        )
        |> Map.put(:disabled_at, nil)
        |> Map.put(:disabled_reason, nil)

      {:ok, attrs}
    else
      {:error, :retry_later} ->
        {:error, :fetch_product_failed}
    end
  end

  defp update_account(customer_id, attrs) do
    case update_account_by_stripe_customer_id(customer_id, attrs) do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to update account on Stripe subscription event",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Account Creation

  defp create_account_from_stripe_customer(%{"metadata" => %{"account_id" => _account_id}}) do
    :ok
  end

  defp create_account_from_stripe_customer(%{
         "id" => customer_id,
         "name" => customer_name,
         "email" => account_email,
         "metadata" => metadata
       })
       when is_map_key(metadata, "company_website") and
              is_map_key(metadata, "account_owner_first_name") and
              is_map_key(metadata, "account_owner_last_name") do
    account_slug = generate_account_slug(metadata)

    attrs = %{
      name: metadata["account_name"] || customer_name,
      legal_name: customer_name,
      slug: account_slug,
      metadata: %{
        stripe: %{
          customer_id: customer_id,
          billing_email: account_email
        }
      }
    }

    case create_account_with_defaults(attrs, metadata, account_email) do
      :ok ->
        :ok

      {:error, %Ecto.Changeset{errors: [{:slug, {"has already been taken", _}} | _]}} ->
        {:error, :slug_taken}

      {:error, reason} ->
        Logger.error("Failed to create account from Stripe",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, :failed_account_creation}
    end
  end

  defp create_account_from_stripe_customer(%{
         "id" => customer_id,
         "name" => customer_name,
         "metadata" => customer_metadata
       }) do
    Logger.error("Failed to create account from Stripe",
      customer_id: customer_id,
      customer_metadata: inspect(customer_metadata),
      customer_name: customer_name,
      reason: "missing custom metadata keys"
    )

    {:error, :missing_custom_metadata}
  end

  defp generate_account_slug(metadata) do
    cond do
      not is_nil(metadata["account_slug"]) ->
        metadata["account_slug"]

      company_website = metadata["company_website"] ->
        extract_slug_from_uri(company_website)

      true ->
        generate_unique_slug()
    end
  end

  defp extract_slug_from_uri(company_website) do
    uri = URI.parse(company_website)

    cond do
      uri.host ->
        uri.host
        |> String.split(".")
        |> List.delete_at(-1)
        |> Enum.join("_")
        |> String.replace("-", "_")

      uri.path ->
        uri.path
        |> String.split(".")
        |> List.delete_at(-1)
        |> Enum.join("_")
        |> String.replace("-", "_")

      true ->
        generate_unique_slug()
    end
  end

  defp generate_unique_slug do
    slug_candidate = Portal.NameGenerator.generate_slug()

    if DB.slug_exists?(slug_candidate) do
      generate_unique_slug()
    else
      slug_candidate
    end
  end

  # TODO: BILLING OVERHAUL
  # The DB operations should be wrapped in a transaction to ensure atomicity
  defp create_account_with_defaults(attrs, metadata, account_email) do
    with {:ok, account} <- attrs |> create_account_changeset() |> DB.insert(),
         {:ok, account} <- Billing.update_stripe_customer(account),
         {:ok, account} <- Portal.Billing.create_subscription(account),
         :ok <- setup_account_defaults(account, metadata, account_email) do
      :ok
    end
  end

  defp setup_account_defaults(account, metadata, account_email) do
    # Create default groups and resources
    changeset = create_everyone_group_changeset(account)
    {:ok, _everyone_group} = DB.insert(changeset)
    changeset = create_site_changeset(account, %{name: "Default Site"})
    {:ok, _site} = DB.insert_site(changeset)
    changeset = create_internet_site_changeset(account)
    {:ok, internet_site} = DB.insert_site(changeset)
    changeset = create_internet_resource_changeset(account, internet_site)
    {:ok, _resource} = DB.insert(changeset)

    # Create email provider
    {:ok, _email_provider} = DB.create_email_provider(account)

    # Create admin user
    email = metadata["account_admin_email"] || account_email
    given_name = metadata["account_owner_first_name"]
    family_name = metadata["account_owner_last_name"]
    name = "#{given_name} #{family_name}"
    changeset = create_admin_changeset(account, email, name)
    {:ok, _actor} = DB.insert(changeset)

    :ok
  end

  defp create_everyone_group_changeset(account) do
    import Ecto.Changeset
    attrs = %{account_id: account.id, name: "Everyone", type: :managed}
    cast(%Portal.Group{}, attrs, ~w[account_id name type]a)
  end

  defp create_admin_changeset(account, email, name) do
    import Ecto.Changeset

    attrs = %{
      account_id: account.id,
      email: email,
      name: name,
      type: :account_admin_user,
      allow_email_otp_sign_in: true
    }

    cast(%Portal.Actor{}, attrs, ~w[account_id email name type allow_email_otp_sign_in]a)
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
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :sites_account_id_name_index)
  end

  defp create_internet_site_changeset(account) do
    import Ecto.Changeset

    %Portal.Site{
      account_id: account.id,
      managed_by: :system
    }
    |> cast(%{name: "Internet", managed_by: :system}, [:name, :managed_by])
    |> validate_required([:name, :managed_by])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :sites_account_id_name_index)
  end

  defp create_internet_resource_changeset(account, site) do
    import Ecto.Changeset

    attrs = %{
      type: :internet,
      name: "Internet"
    }

    %Portal.Resource{site_id: site.id, account_id: account.id}
    |> cast(attrs, [:type, :name])
    |> validate_required([:name, :type])
  end

  # Account Updates
  defp update_account_by_stripe_customer_id(customer_id, attrs) do
    with {:ok, account_id} <- Billing.fetch_customer_account_id(customer_id) do
      DB.update_account_by_id(account_id, attrs)
    end
  end

  defp account_update_attrs(
         seats,
         product_metadata,
         subscription_metadata,
         stripe_metadata
       ) do
    limit_fields = Accounts.Limits.__schema__(:fields) |> Enum.map(&to_string/1)
    feature_fields = Accounts.Features.__schema__(:fields) |> Enum.map(&to_string/1)
    metadata_fields = ["support_type"]

    params =
      Map.merge(product_metadata, subscription_metadata)
      |> parse_metadata_params(limit_fields, metadata_fields)

    {users_count, params} = Map.pop(params, "users_count", seats)
    {metadata, params} = Map.split(params, metadata_fields)
    {limits, params} = Map.split(params, limit_fields)
    {features, _} = Map.split(params, feature_fields)

    limits = Map.merge(limits, %{"users_count" => users_count})

    %{
      features: features,
      limits: limits,
      metadata: %{stripe: Map.merge(metadata, stripe_metadata)}
    }
  end

  defp parse_metadata_params(metadata, limit_fields, metadata_fields) do
    metadata
    |> Enum.flat_map(fn
      {feature, "true"} ->
        [{feature, true}]

      {feature, "false"} ->
        [{feature, false}]

      {feature, true} ->
        [{feature, true}]

      {feature, false} ->
        [{feature, false}]

      {key, value} ->
        cond do
          key in limit_fields -> [{key, cast_limit(value)}]
          key in metadata_fields -> [{key, value}]
          true -> []
        end
    end)
    |> Enum.into(%{})
  end

  # Utility Functions
  defp cast_limit(number) when is_number(number), do: number
  defp cast_limit("unlimited"), do: nil
  defp cast_limit(binary) when is_binary(binary), do: String.to_integer(binary)

  defp put_if_not_nil(map, _key, nil), do: map
  defp put_if_not_nil(map, key, value), do: Map.put(map, key, value)

  defp create_account_changeset(attrs) do
    import Ecto.Changeset

    %Portal.Account{}
    |> cast(attrs, [:name])
    |> cast_embed(:metadata)
    |> validate_required([:name])
  end

  defmodule DB do
    import Ecto.Query
    import Ecto.Changeset

    alias Portal.{
      Account,
      AuthProvider,
      EmailOTP,
      Safe
    }

    def with_customer_lock(customer_id, fun) do
      hashed_id = :erlang.phash2(customer_id)

      Safe.transact(fn ->
        {:ok, _} = Safe.unscoped() |> Safe.query("SELECT pg_advisory_xact_lock($1)", [hashed_id])
        fun.()
      end)
    end

    def slug_exists?(slug) do
      from(a in Portal.Account, where: a.slug == ^slug)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def create_email_provider(account) do
      id = Ecto.UUID.generate()
      attrs = %{account_id: account.id, id: id, type: :email_otp}
      parent_changeset = cast(%AuthProvider{}, attrs, ~w[id account_id type]a)
      attrs = %{id: id, name: "Email (OTP)"}

      changeset = cast(%EmailOTP.AuthProvider{}, attrs, ~w[id name]a)

      with {:ok, _auth_provider} <- Safe.unscoped(parent_changeset) |> Safe.insert(),
           {:ok, email_provider} <- Safe.unscoped(changeset) |> Safe.insert() do
        {:ok, email_provider}
      end
    end

    def insert(changeset) do
      Safe.unscoped(changeset)
      |> Safe.insert()
    end

    def update_account_by_id(id, attrs) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
      |> case do
        %Account{} = account ->
          account
          |> cast(attrs, [])
          |> cast_embed(:limits)
          |> cast_embed(:features)
          |> cast_embed(:metadata)
          |> Safe.unscoped()
          |> Safe.update()
      end
    end

    def insert_site(changeset) do
      Safe.unscoped(changeset)
      |> Safe.insert()
    end
  end
end
