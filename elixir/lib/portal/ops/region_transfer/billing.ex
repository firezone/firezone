defmodule Portal.Ops.RegionTransfer.Billing do
  @moduledoc """
  Moves the Stripe billing of an account to the Stripe account of the other
  region, for `Portal.Ops.RegionTransfer.initiate/2` and `complete/2`.

  In the source, the subscription is set to cancel at the end of the period
  the customer already paid for, which a rollback undoes. In the destination,
  a new subscription with the destination prices, currency and coupon starts
  active and renews on that same date, with no invoice before it.

  The destination uses the customer copied with Stripe's Dashboard copy tool
  when there is one, because only that carries a saved card over. Otherwise it
  creates a customer, and a customer who pays by card adds one before the
  renewal date. Stripe has no public API for the copy.
  """
  alias Portal.Billing.EventHandler
  alias Portal.Billing.Stripe.APIClient
  alias __MODULE__.Database

  @reason "Region transfer in progress"
  @closed_statuses ~w(canceled incomplete_expired)
  @unsupported_terms ~w(schedule pause_collection pending_update pending_invoice_item_interval billing_thresholds transfer_data on_behalf_of cancel_at)

  @doc false
  def snapshot(account) do
    with true <- Portal.Billing.enabled?(),
         {:ok, customer_id} <- customer_id(account),
         {:ok, snapshot} <- fetch_snapshot(customer_id) do
      {:ok, without_scheduled_cancel(snapshot, account.metadata.region_transfer)}
    else
      false -> {:ok, nil}
      {:error, :no_stripe_customer} -> {:ok, nil}
      error -> error
    end
  end

  # A rerun of initiate/2 sees the cancel that the first run scheduled.
  defp without_scheduled_cancel(snapshot, %{"cancel_scheduled" => ids}) do
    Map.update!(snapshot, "subscriptions", fn subscriptions -> Enum.map(subscriptions, &unschedule(&1, ids)) end)
  end

  defp without_scheduled_cancel(snapshot, _state), do: snapshot

  defp unschedule(subscription, ids) do
    if subscription["id"] in ids,
      do: Map.merge(subscription, %{"cancel_at_period_end" => false, "cancel_at" => nil}),
      else: subscription
  end

  @doc "Refuses a transfer while the customer owes anything in Stripe."
  def nothing_owed(nil), do: :ok

  def nothing_owed(snapshot) do
    case snapshot["unsettled_invoice_ids"] ++ snapshot["open_invoice_ids"] ++ snapshot["pending_invoice_item_ids"] do
      [] -> :ok
      ids -> {:error, {:billing_outstanding, ids}}
    end
  end

  @doc """
  Sets the source subscriptions to cancel at the end of the period the
  customer paid for, and records them so `resume_source/1` can undo it.
  """
  def schedule_source_cancel(account) do
    with %{"snapshot" => snapshot} = state <- account.metadata.region_transfer || {:ok, account},
         ids = Enum.map(snapshot["subscriptions"], & &1["id"]),
         {:ok, _subscriptions} <- map_while(ids, &set_cancel_at_period_end(&1, true)) do
      Database.put_state(account, Map.put(state, "cancel_scheduled", ids))
    end
  end

  @doc "Undoes `schedule_source_cancel/1` for a rollback."
  def resume_source(account) do
    case account.metadata.region_transfer do
      %{"cancel_scheduled" => ids} = state ->
        with {:ok, _subscriptions} <- map_while(ids, &set_cancel_at_period_end(&1, false)) do
          Database.put_state(account, Map.delete(state, "cancel_scheduled"))
        end

      _state ->
        {:ok, account}
    end
  end

  defp set_cancel_at_period_end(subscription_id, cancel?) do
    request(:post, "subscriptions/#{subscription_id}", URI.encode_query(%{"cancel_at_period_end" => cancel?}))
  end

  @doc "Whether `complete/2` still has to create the subscription."
  def pending?(%{metadata: %{region_transfer: %{"status" => "pending"}}}), do: true
  def pending?(_account), do: false

  @doc false
  def transfer_state(nil, _status), do: nil
  def transfer_state(snapshot, status), do: %{"status" => status, "snapshot" => snapshot}

  @doc "Shows the subscription that `migrate/2` creates. Changes nothing."
  def plan(account_id, opts \\ []) do
    with {:ok, plan} <- account_id |> Database.fetch_account!() |> build_plan(opts) do
      print_plan(plan)
      {:ok, plan}
    end
  end

  @doc """
  Creates the subscription in the Stripe account of this region, or finds the
  one an earlier run created, and applies it to the account.

  Pass `price_map: %{"source price" => "destination price"}` or
  `coupon_map: %{"source coupon" => "destination coupon"}` when none or more
  than one matches, and `customer: "cus_..."` when more than one customer
  here names the account.
  """
  def migrate(account_id, opts \\ []) do
    with {:ok, plan} <- plan(account_id, opts),
         :ok <- confirm(opts, "Create this subscription? [y/N]") do
      Database.with_lock(account_id, fn -> create_and_apply(account_id, plan, opts) end)
    end
  end

  @doc false
  def ready?(account, opts \\ []) do
    state = account.metadata.region_transfer

    cond do
      Keyword.get(opts, :billing) == :skip -> :ok
      not Portal.Billing.enabled?() -> :ok
      is_nil(state) and match?({:ok, _}, customer_id(account)) -> {:error, :billing_snapshot_missing}
      is_nil(state) -> :ok
      true -> state_ready(account, state)
    end
  end

  defp state_ready(_account, %{"status" => "exported", "snapshot" => snapshot}) do
    if snapshot["source_region"] == region(), do: :ok, else: {:error, :billing_not_migrated}
  end

  defp state_ready(account, %{"status" => "ready", "destination_subscription_id" => id}) do
    stripe = account.metadata.stripe

    if stripe.subscription_id == id and stripe.subscription_status in ["active", "trialing"],
      do: :ok,
      else: {:error, :billing_not_applied}
  end

  defp state_ready(_account, _state), do: {:error, :billing_not_migrated}

  defp fetch_snapshot(customer_id) do
    with {:ok, stripe_account} <- get("account"),
         {:ok, customer} <- get("customers/#{customer_id}"),
         {:ok, subscriptions} <- list("subscriptions", customer: customer_id, status: "all"),
         {:ok, subscriptions} <- subscriptions |> Enum.reject(&(&1["status"] in @closed_statuses)) |> expand_products(),
         {:ok, invoices} <- list("invoices", customer: customer_id),
         {:ok, invoice_items} <- list("invoiceitems", customer: customer_id, pending: true) do
      {:ok,
       %{
         "source_region" => region(),
         "source_stripe_account_id" => stripe_account["id"],
         "customer" => customer,
         "subscriptions" => subscriptions,
         "unsettled_invoice_ids" => for(i <- invoices, unsettled?(i), do: i["id"]),
         "open_invoice_ids" => for(i <- invoices, i["status"] == "open" and not unsettled?(i), do: i["id"]),
         "pending_invoice_item_ids" => Enum.map(invoice_items, & &1["id"])
       }}
    end
  end

  # A sent invoice that is not paid yet stays in the source Stripe account,
  # and the customer pays it there. A draft, a failed automatic payment or an
  # uncollectible invoice needs a decision first.
  defp unsettled?(%{"status" => "open", "collection_method" => "send_invoice"}), do: false
  defp unsettled?(%{"status" => status}), do: status in ~w(draft open uncollectible)

  defp build_plan(account, opts) do
    with :ok <- in_transfer(account),
         {:ok, snapshot} <- destination_snapshot(account),
         {:ok, destination} <- get("account"),
         true <- destination["id"] != snapshot["source_stripe_account_id"] || {:error, :same_stripe_account},
         {:ok, customer} <- destination_customer(account, snapshot, opts),
         :ok <- supported_customer(snapshot["customer"]),
         :ok <- supported_customer(customer),
         {:ok, subscription} <- source_subscription(snapshot),
         {:ok, items} <- map_items(subscription, opts),
         {:ok, coupon} <- map_coupon(subscription["discount"], opts) do
      {payment, warnings} = payment_params(snapshot["customer"], customer, subscription, coupon, opts)

      params =
        account
        |> subscription_params(snapshot, subscription, customer, items, payment)
        |> put_coupon(coupon)

      {:ok,
       %{
         "destination_stripe_account_id" => destination["id"],
         "source_stripe_account_id" => snapshot["source_stripe_account_id"],
         "source_subscription_id" => subscription["id"],
         "customer_id" => customer["id"],
         "new_customer" => if(customer["id"], do: nil, else: new_customer_params(snapshot["customer"])),
         "warnings" => warnings,
         "renews_at" => subscription["current_period_end"],
         "items" => items,
         "coupon" => coupon && %{"id" => coupon["id"], "name" => coupon["name"]},
         "params" => params
       }}
    end
  end

  defp subscription_params(account, snapshot, subscription, customer, items, payment) do
    base = %{
      "customer" => customer["id"],
      "collection_method" => subscription["collection_method"],
      "proration_behavior" => "none",
      "automatic_tax[enabled]" => get_in(subscription, ["automatic_tax", "enabled"]) == true,
      "metadata[account_id]" => account.id,
      "metadata[region_transfer_source_account]" => snapshot["source_stripe_account_id"],
      "metadata[region_transfer_source_subscription]" => subscription["id"]
    }

    # The customer already paid until the renewal date. An anchor there
    # starts the subscription active with no invoice until then, while a
    # real trial, such as a pilot, stays a trial until the same date.
    base =
      case subscription["status"] do
        "active" -> Map.put(base, "billing_cycle_anchor", subscription["current_period_end"])
        "trialing" -> Map.put(base, "trial_end", subscription["current_period_end"])
      end

    base =
      case subscription["collection_method"] do
        "send_invoice" -> Map.put(base, "days_until_due", subscription["days_until_due"])
        "charge_automatically" -> Map.put(base, "payment_behavior", "error_if_incomplete")
      end

    base = if subscription["description"], do: Map.put(base, "description", subscription["description"]), else: base

    base =
      (get_in(subscription, ["payment_settings", "payment_method_types"]) || [])
      |> Enum.with_index()
      |> Enum.reduce(base, fn {type, i}, acc -> Map.put(acc, "payment_settings[payment_method_types][#{i}]", type) end)

    params =
      items
      |> Enum.with_index()
      |> Enum.reduce(base, fn {item, i}, acc ->
        acc
        |> Map.put("items[#{i}][price]", item["price"])
        |> Map.put("items[#{i}][quantity]", item["quantity"])
      end)
      |> Map.merge(payment)

    params =
      Enum.reduce(subscription["metadata"] || %{}, params, fn {key, value}, acc ->
        Map.put_new(acc, "metadata[#{key}]", value)
      end)

    params
  end

  defp put_coupon(params, coupon) do
    params = if coupon, do: Map.put(params, "coupon", coupon["id"]), else: params
    Map.put(params, "metadata[region_transfer_plan]", fingerprint(Map.delete(params, "customer")))
  end

  # Coupons are not copied with the customer. The destination has the same
  # coupons, so the one with the same name and terms is used. A repeating
  # coupon would start its months over, so it needs a decision.
  defp map_coupon(nil, _opts), do: {:ok, nil}

  defp map_coupon(%{"coupon" => %{"duration" => "repeating"} = coupon}, _opts),
    do: {:error, {:coupon_requires_review, coupon["id"]}}

  defp map_coupon(%{"coupon" => source}, opts) do
    override = Keyword.get(opts, :coupon_map, %{})[source["id"]]

    with {:ok, coupons} <- list("coupons", []) do
      case Enum.filter(coupons, &coupon_match?(&1, source, override)) do
        [coupon] -> {:ok, coupon}
        candidates -> {:error, {:coupon_mapping_required, source["id"], Enum.map(candidates, & &1["id"])}}
      end
    end
  end

  defp coupon_match?(%{"valid" => true, "id" => id}, _source, override) when is_binary(override), do: id == override
  defp coupon_match?(%{"valid" => true} = coupon, source, nil), do: same_coupon?(source, coupon)
  defp coupon_match?(_coupon, _source, _override), do: false

  defp same_coupon?(source, coupon) do
    Enum.all?(~w(name percent_off amount_off duration duration_in_months), &(source[&1] == coupon[&1])) and
      (is_nil(coupon["amount_off"]) or coupon["currency"] == currency())
  end

  defp fingerprint(params) do
    params |> Enum.sort() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  # The copied customer, under its original ID or found by the account ID in
  # its metadata. Without one, complete/2 creates a customer.
  defp destination_customer(account, snapshot, opts) do
    source = snapshot["customer"]

    with {:ok, candidates} <- customer_candidates(account, source["id"], Keyword.get(opts, :customer)) do
      case Enum.reject(candidates, &(&1["deleted"] == true)) do
        [] -> {:ok, %{"id" => nil}}
        [customer] -> verify_customer(account, source, customer)
        customers -> {:error, {:multiple_customers, Enum.map(customers, & &1["id"])}}
      end
    end
  end

  defp customer_candidates(_account, _source_id, chosen) when is_binary(chosen) do
    with {:ok, customer} <- get("customers/#{chosen}"), do: {:ok, [customer]}
  end

  defp customer_candidates(account, source_id, nil) do
    case get("customers/#{source_id}") do
      {:ok, %{"deleted" => true}} -> search_customers(account)
      {:ok, customer} -> {:ok, [customer]}
      {:error, {404, _}} -> search_customers(account)
      error -> error
    end
  end

  defp search_customers(account) do
    query = URI.encode_query(%{"query" => "metadata['account_id']:'#{account.id}'", "limit" => 100})

    with {:ok, %{"data" => customers}} <- get("customers/search?" <> query), do: {:ok, customers}
  end

  defp verify_customer(account, source, customer) do
    cond do
      customer["livemode"] != source["livemode"] -> {:error, :stripe_mode_mismatch}
      get_in(customer, ["metadata", "account_id"]) != account.id -> {:error, {:customer_account_mismatch, customer["id"]}}
      true -> {:ok, customer}
    end
  end

  defp new_customer_params(source) do
    address = for {k, v} <- source["address"] || %{}, v != nil, into: %{}, do: {"address[#{k}]", v}
    metadata = for {k, v} <- source["metadata"] || %{}, into: %{}, do: {"metadata[#{k}]", v}

    %{"name" => source["name"], "email" => source["email"], "phone" => source["phone"]}
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.merge(address)
    |> Map.merge(metadata)
  end

  defp supported_customer(customer) do
    if (customer["balance"] || 0) != 0 or customer["discount"] != nil or customer["tax_exempt"] not in [nil, "none"],
      do: {:error, {:customer_requires_review, customer["id"]}},
      else: :ok
  end

  defp source_subscription(snapshot) do
    cond do
      snapshot["pending_invoice_item_ids"] != [] -> {:error, {:pending_invoice_items, snapshot["pending_invoice_item_ids"]}}
      snapshot["unsettled_invoice_ids"] != [] -> {:error, {:unsettled_invoices, snapshot["unsettled_invoice_ids"]}}
      length(snapshot["subscriptions"]) != 1 -> {:error, {:expected_one_subscription, length(snapshot["subscriptions"])}}
      true -> snapshot["subscriptions"] |> hd() |> supported_subscription()
    end
  end

  defp supported_subscription(subscription) do
    cond do
      subscription["status"] not in ["active", "trialing"] ->
        {:error, {:subscription_status, subscription["status"]}}

      Enum.any?(@unsupported_terms, &(subscription[&1] != nil)) or subscription["cancel_at_period_end"] == true or
        (subscription["default_tax_rates"] || []) != [] or
        length(subscription["discounts"] || []) != if(subscription["discount"], do: 1, else: 0) ->
        {:error, {:subscription_requires_review, subscription["id"]}}

      get_in(subscription, ["items", "has_more"]) == true or not default_invoice_settings?(subscription) ->
        {:error, {:subscription_requires_review, subscription["id"]}}

      true ->
        {:ok, subscription}
    end
  end

  # Tax IDs and payment method options belong to the source Stripe account and
  # cannot be carried over.
  defp default_invoice_settings?(subscription) do
    (get_in(subscription, ["invoice_settings", "account_tax_ids"]) || []) == [] and
      get_in(subscription, ["invoice_settings", "issuer", "type"]) in [nil, "self"] and
      (get_in(subscription, ["payment_settings", "payment_method_options"]) || %{})
      |> Map.values()
      |> Enum.all?(&is_nil/1)
  end

  # Matches each source price to a destination price of the same product name,
  # amount and interval in the destination currency. This is not a currency
  # conversion: a price without exactly one match needs `price_map`.
  defp map_items(subscription, opts) do
    price_map = Keyword.get(opts, :price_map, %{})

    with {:ok, prices} <- list("prices", active: true, currency: currency(), "expand[]": "data.product") do
      map_while(subscription["items"]["data"], &map_item(&1, prices, price_map[&1["price"]["id"]]))
    end
  end

  defp map_while(enumerable, fun) do
    Enum.reduce_while(enumerable, {:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, mapped} -> {:cont, {:ok, acc ++ [mapped]}}
        error -> {:halt, error}
      end
    end)
  end

  defp map_item(item, prices, override) do
    source = item["price"]

    candidates =
      Enum.filter(prices, fn price ->
        if override, do: price["id"] == override, else: same_price?(source, price)
      end)

    case candidates do
      [price] ->
        if compatible_price?(source, price) and (item["tax_rates"] || []) == [] and is_integer(item["quantity"]) do
          {:ok,
           %{
             "price" => price["id"],
             "quantity" => item["quantity"],
             "product" => get_in(price, ["product", "name"]),
             "unit_amount" => price["unit_amount"]
           }}
        else
          {:error, {:unsupported_price, source["id"]}}
        end

      candidates ->
        {:error, {:price_mapping_required, source["id"], Enum.map(candidates, & &1["id"])}}
    end
  end

  defp same_price?(source, price) do
    is_map(source["product"]) and is_map(price["product"]) and
      source["product"]["name"] == price["product"]["name"] and
      source["unit_amount"] == price["unit_amount"] and
      source["tax_behavior"] == price["tax_behavior"] and
      compatible_price?(source, price)
  end

  defp compatible_price?(source, price) do
    source["billing_scheme"] == "per_unit" and price["billing_scheme"] == "per_unit" and
      is_integer(source["unit_amount"]) and is_integer(price["unit_amount"]) and
      is_map(source["recurring"]) and source["recurring"] == price["recurring"] and
      source["recurring"]["usage_type"] == "licensed" and
      source["transform_quantity"] == price["transform_quantity"]
  end

  # A copied customer keeps its default payment method. A payment method set
  # on the subscription itself has a new ID after the copy, from Stripe's
  # mapping file. Without a payment method, the customer adds one with
  # Manage plan before the renewal date.
  defp payment_params(source_customer, customer, subscription, coupon, opts) do
    override = subscription["default_payment_method"] || subscription["default_source"]
    mapped = Keyword.get(opts, :payment_method_map, %{})[override]

    payment = mapped_payment(mapped)

    no_payment? =
      charged_by_card?(subscription, coupon) and payment == %{} and
        (customer["id"] == nil or default_payment(customer) == nil or
           (override != nil and override != default_payment(source_customer)))

    {payment, if(no_payment?, do: ["no payment method: the customer adds one with Manage plan before the renewal date"], else: [])}
  end

  defp mapped_payment(nil), do: %{}
  defp mapped_payment("pm_" <> _ = id), do: %{"default_payment_method" => id}
  defp mapped_payment(id), do: %{"default_source" => id}

  defp charged_by_card?(subscription, coupon) do
    subscription["collection_method"] == "charge_automatically" and
      Enum.any?(subscription["items"]["data"], &((&1["price"]["unit_amount"] || 0) > 0)) and
      not (is_map(coupon) and coupon["duration"] == "forever" and coupon["percent_off"] == 100)
  end

  defp default_payment(customer) do
    get_in(customer, ["invoice_settings", "default_payment_method"]) || customer["default_source"]
  end

  defp create_and_apply(account_id, plan, opts) do
    account = Database.fetch_account!(account_id)

    with {:ok, current} <- build_plan(account, opts),
         true <- current == plan || {:error, :billing_plan_changed},
         {:ok, plan} <- ensure_customer(plan),
         {:ok, subscription} <- find_or_create(plan),
         true <- subscription["status"] in ["active", "trialing"] || {:error, {:subscription_status, subscription["status"]}},
         {:ok, _account} <- Database.put_customer_id(account, plan["customer_id"]),
         {:ok, account} <- EventHandler.sync_region_transfer_subscription(account_id, subscription),
         state = Map.merge(account.metadata.region_transfer, %{"status" => "ready", "destination_subscription_id" => subscription["id"]}),
         {:ok, _account} <- Database.put_state(account, state) do
      IO.puts("Created #{subscription["id"]}. It renews on #{format_time(plan["renews_at"])}.")
      {:ok, subscription["id"]}
    end
  end

  defp ensure_customer(%{"new_customer" => nil} = plan), do: {:ok, plan}

  defp ensure_customer(%{"new_customer" => params} = plan) do
    key = "region-transfer-customer-#{plan["source_subscription_id"]}"

    with {:ok, customer} <- request(:post, "customers", URI.encode_query(params), idempotency_key: key) do
      {:ok, %{plan | "customer_id" => customer["id"], "params" => Map.put(plan["params"], "customer", customer["id"])}}
    end
  end

  # Stripe forgets idempotency keys after 24 hours, so a rerun looks for the
  # subscription of an earlier run before it creates one.
  defp find_or_create(plan) do
    with {:ok, subscriptions} <- list("subscriptions", customer: plan["customer_id"], status: "all") do
      case subscriptions do
        [] -> create(plan)
        [subscription] -> reuse(subscription, plan)
        subscriptions -> {:error, {:destination_subscription_conflict, Enum.map(subscriptions, & &1["id"])}}
      end
    end
  end

  defp create(plan) do
    if plan["renews_at"] > System.os_time(:second) + 60 do
      key = "region-transfer-#{plan["source_subscription_id"]}-#{plan["params"]["metadata[region_transfer_plan]"]}"
      request(:post, "subscriptions", URI.encode_query(plan["params"]), idempotency_key: key)
    else
      {:error, :renewal_date_passed}
    end
  end

  defp reuse(subscription, plan) do
    actual = Enum.map(subscription["items"]["data"], &{&1["price"]["id"], &1["quantity"]})
    expected = Enum.map(plan["items"], &{&1["price"], &1["quantity"]})

    if subscription["metadata"]["region_transfer_plan"] == plan["params"]["metadata[region_transfer_plan]"] and
         subscription["current_period_end"] == plan["renews_at"] and Enum.sort(actual) == Enum.sort(expected),
       do: {:ok, subscription},
       else: {:error, {:destination_subscription_conflict, subscription["id"]}}
  end

  defp destination_snapshot(account) do
    case account.metadata.region_transfer do
      %{"status" => status, "snapshot" => snapshot} when status in ["pending", "ready"] ->
        if snapshot["source_region"] != region(), do: {:ok, snapshot}, else: {:error, :run_in_destination}

      _state ->
        {:error, :billing_snapshot_missing}
    end
  end

  defp expand_products(subscriptions) do
    map_while(subscriptions, fn subscription ->
      with {:ok, items} <- map_while(subscription["items"]["data"], &expand_product/1) do
        {:ok, put_in(subscription, ["items", "data"], items)}
      end
    end)
  end

  defp expand_product(item) do
    with {:ok, product} <- get("products/#{item["price"]["product"]}") do
      {:ok, put_in(item, ["price", "product"], product)}
    end
  end

  defp list(path, params, acc \\ []) do
    with {:ok, %{"data" => data, "has_more" => more?}} <- get(path <> "?" <> URI.encode_query([{:limit, 100} | params])) do
      if more?,
        do: list(path, Keyword.put(params, :starting_after, List.last(data)["id"]), acc ++ data),
        else: {:ok, acc ++ data}
    end
  end

  defp get(path), do: request(:get, path)

  defp request(method, path, body \\ nil, opts \\ []) do
    secret_key = Portal.Config.fetch_env!(:portal, Portal.Billing) |> Keyword.fetch!(:secret_key)
    APIClient.request(secret_key, method, path, body, opts)
  end

  defp print_plan(plan) do
    IO.puts("""
    Billing of #{if plan["customer_id"], do: "customer #{plan["customer_id"]}", else: "a new customer"} in Stripe account #{plan["destination_stripe_account_id"]}
      Replaces subscription #{plan["source_subscription_id"]} of Stripe account #{plan["source_stripe_account_id"]}
      Renews on #{format_time(plan["renews_at"])}, with no charge until then
    """)

    for item <- plan["items"] do
      IO.puts("  #{item["quantity"]} x #{item["product"]} (#{item["price"]}, #{item["unit_amount"]} #{currency()})")
    end

    if plan["coupon"] do
      IO.puts("  Coupon #{plan["coupon"]["name"]} (#{plan["coupon"]["id"]})")
    end

    for warning <- plan["warnings"] do
      IO.puts("  Warning: #{warning}")
    end
  end

  defp format_time(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp region, do: :portal |> Portal.Config.fetch_env!(:data_residency_region) |> Atom.to_string()

  defp currency do
    case Portal.Config.fetch_env!(:portal, :data_residency_region) do
      :eu -> "eur"
      :us -> "usd"
    end
  end

  defp customer_id(%{metadata: %{stripe: %{customer_id: id}}}) when is_binary(id), do: {:ok, id}
  defp customer_id(_account), do: {:error, :no_stripe_customer}

  defp in_transfer(%{is_disabled: true, disabled_reason: @reason}), do: :ok
  defp in_transfer(account), do: {:error, {:not_in_transfer, account.disabled_reason}}

  defp confirm(opts, prompt) do
    if Keyword.get(opts, :confirm, true) do
      IO.puts(prompt)

      case IO.gets("") |> String.trim() |> String.downcase() do
        "y" ->
          :ok

        _answer ->
          IO.puts("Aborted.")
          :aborted
      end
    else
      :ok
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def fetch_account!(id) do
      from(a in Portal.Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    # The Stripe calls run inside the transaction, so a second run waits for
    # the first and then finds its subscription.
    def with_lock(account_id, fun) do
      Safe.transact(
        fn ->
          {:ok, _result} =
            Safe.unscoped()
            |> Safe.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["region-transfer-billing:" <> account_id])

          fun.()
        end,
        timeout: :timer.minutes(2)
      )
    end

    def put_state(account, state) do
      account
      |> Ecto.Changeset.cast(%{metadata: %{region_transfer: state}}, [])
      |> Ecto.Changeset.cast_embed(:metadata)
      |> Safe.unscoped()
      |> Safe.update()
    end

    def put_customer_id(%{metadata: %{stripe: %{customer_id: id}}} = account, id), do: {:ok, account}

    def put_customer_id(account, customer_id) do
      account
      |> Ecto.Changeset.cast(%{metadata: %{stripe: %{customer_id: customer_id}}}, [])
      |> Ecto.Changeset.cast_embed(:metadata)
      |> Safe.unscoped()
      |> Safe.update()
    end
  end
end
