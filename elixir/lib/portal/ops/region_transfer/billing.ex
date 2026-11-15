defmodule Portal.Ops.RegionTransfer.Billing do
  @moduledoc """
  Moves the Stripe billing of an account to the Stripe account of the other
  region.

  Stripe has no public API to copy a customer between Stripe accounts, so the
  customer is copied with the Stripe Dashboard before the maintenance window.
  The copy keeps the customer ID and the payment methods. It does not copy
  subscriptions, prices or invoices, so the invoice history stays in the
  source Stripe account.

  The new subscription uses the prices and the currency of the destination. It
  keeps the renewal date of the source subscription with a trial that ends on
  that date, as Stripe recommends for a migration. The customer is not charged
  again for time they already paid for, and gets no refund or credit for it.
  """
  alias Portal.Billing.EventHandler
  alias Portal.Billing.Stripe.APIClient
  alias __MODULE__.Database

  @reason "Region transfer in progress"
  @closed_statuses ~w(canceled incomplete_expired)
  @unsupported_terms ~w(discount schedule pause_collection pending_update pending_invoice_item_interval billing_thresholds transfer_data on_behalf_of cancel_at)

  @doc "Shows the customer to copy with the Stripe Dashboard. Changes nothing."
  def prepare_copy(account_id) do
    account = Database.fetch_account!(account_id)

    with {:ok, customer_id} <- customer_id(account),
         {:ok, stripe_account} <- get("account"),
         {:ok, _customer} <- get("customers/#{customer_id}") do
      IO.puts("""
      In Stripe account #{stripe_account["id"]}, copy only customer #{customer_id} to the
      Stripe account of the other region, accept the copy there, and wait for it to finish
      before the maintenance window. A CSV upload takes one column of customer IDs without
      a header.
      """)

      {:ok, %{source_stripe_account_id: stripe_account["id"], customer_id: customer_id}}
    end
  end

  @doc false
  def snapshot(account) do
    with true <- Portal.Billing.enabled?(),
         {:ok, customer_id} <- customer_id(account) do
      fetch_snapshot(customer_id)
    else
      false -> {:ok, nil}
      {:error, :no_stripe_customer} -> {:ok, nil}
    end
  end

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

  Pass `price_map: %{"price_source" => "price_destination"}` when a price has
  no single match, `payment_method_map:` with the IDs from Stripe's copy
  mapping file when the source subscription has its own payment method, and
  `replace_customer: "cus_..."` when the account points at a customer that was
  created in this Stripe account instead of copied. Pass
  `copied_customer: "cus_..."` when the copy gave the customer a new ID, as
  Stripe's mapping file shows.
  """
  def migrate(account_id, opts \\ []) do
    with {:ok, plan} <- plan(account_id, opts),
         :ok <- confirm(opts, "Create this subscription? [y/N]") do
      Database.with_lock(account_id, fn -> create_and_apply(account_id, plan, opts) end)
    end
  end

  @doc """
  Cancels the subscriptions in the source Stripe account without a final
  invoice or proration. Run it only after the billing in the destination is
  verified. It cannot be undone.
  """
  def finish_source(account_id, opts \\ []) do
    account = Database.fetch_account!(account_id)

    with :ok <- in_transfer(account),
         {:ok, snapshot} <- source_snapshot(account),
         {:ok, stripe_account} <- get("account"),
         true <- stripe_account["id"] == snapshot["source_stripe_account_id"] || {:error, :wrong_stripe_account},
         {:ok, subscriptions} <- list("subscriptions", customer: snapshot["customer"]["id"], status: "all"),
         open = Enum.reject(subscriptions, &(&1["status"] in @closed_statuses)),
         :ok <- unchanged_since_export(open, snapshot),
         IO.puts("Subscriptions to cancel without proration: #{Enum.map_join(open, ", ", & &1["id"])}"),
         :ok <- confirm(opts, "Is the billing in the destination verified? Cancel these subscriptions? [y/N]"),
         :ok <- cancel_all(open),
         :ok <- keep_collecting_invoices(snapshot["customer"]["id"]) do
      Database.put_state(account, %{account.metadata.region_transfer | "status" => "source_canceled"})
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

  defp state_ready(_account, %{"status" => "source_canceled"}), do: {:error, :source_billing_canceled}
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
         copied_id = Keyword.get(opts, :copied_customer, snapshot["customer"]["id"]),
         {:ok, replaced} <- current_customer(account, snapshot, copied_id, opts),
         {:ok, customer} <- copied_customer(account, snapshot, copied_id),
         :ok <- supported_customer(snapshot["customer"]),
         :ok <- supported_customer(customer),
         {:ok, subscription} <- source_subscription(snapshot),
         {:ok, items} <- map_items(subscription, opts),
         {:ok, payment} <- payment_params(snapshot["customer"], customer, subscription, opts) do
      params = subscription_params(account, snapshot, subscription, customer, items, payment)

      {:ok,
       %{
         "destination_stripe_account_id" => destination["id"],
         "source_stripe_account_id" => snapshot["source_stripe_account_id"],
         "source_subscription_id" => subscription["id"],
         "customer_id" => customer["id"],
         "replace_customer_id" => replaced,
         "open_invoice_ids" => snapshot["open_invoice_ids"],
         "renews_at" => subscription["current_period_end"],
         "items" => items,
         "params" => params
       }}
    end
  end

  defp subscription_params(account, snapshot, subscription, customer, items, payment) do
    base = %{
      "customer" => customer["id"],
      "collection_method" => subscription["collection_method"],
      "proration_behavior" => "none",
      "trial_end" => subscription["current_period_end"],
      "automatic_tax[enabled]" => get_in(subscription, ["automatic_tax", "enabled"]) == true,
      "metadata[account_id]" => account.id,
      "metadata[region_transfer_source_account]" => snapshot["source_stripe_account_id"],
      "metadata[region_transfer_source_subscription]" => subscription["id"]
    }

    # Marks the trial as time the customer already paid for, so the portal
    # shows no trial and does not count the renewal as a new enrollment.
    base =
      if subscription["status"] == "active",
        do: Map.put(base, "metadata[region_transfer_prepaid_until]", to_string(subscription["current_period_end"])),
        else: base

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

    Map.put(params, "metadata[region_transfer_plan]", fingerprint(params))
  end

  defp fingerprint(params) do
    params |> Enum.sort() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp current_customer(account, snapshot, copied_id, opts) do
    source_id = snapshot["customer"]["id"]
    replace = Keyword.get(opts, :replace_customer)

    case account.metadata.stripe.customer_id do
      ^source_id -> {:ok, nil}
      ^copied_id -> {:ok, nil}
      ^replace when is_binary(replace) -> replaceable_customer(account, replace)
      other -> {:error, {:unexpected_customer, other}}
    end
  end

  # The customer made by hand must be deleted, or be this account's and not
  # bill it. A deleted customer has nothing left to unlink.
  defp replaceable_customer(account, customer_id) do
    case get("customers/#{customer_id}") do
      {:ok, %{"deleted" => true}} -> {:ok, nil}
      {:ok, customer} -> unused_customer(account, customer)
      error -> error
    end
  end

  defp unused_customer(account, customer) do
    with true <- get_in(customer, ["metadata", "account_id"]) == account.id || {:error, {:unexpected_customer, customer["id"]}},
         {:ok, subscriptions} <- list("subscriptions", customer: customer["id"], status: "all"),
         [] <- for(s <- subscriptions, s["status"] not in @closed_statuses, do: s["id"]) do
      {:ok, customer["id"]}
    else
      ids when is_list(ids) -> {:error, {:replaced_customer_has_subscriptions, ids}}
      error -> error
    end
  end

  defp copied_customer(account, snapshot, copied_id) do
    source = snapshot["customer"]

    case get("customers/#{copied_id}") do
      {:ok, %{"deleted" => true}} ->
        {:error, :copied_customer_deleted}

      {:ok, customer} ->
        cond do
          customer["livemode"] != source["livemode"] -> {:error, :stripe_mode_mismatch}
          get_in(customer, ["metadata", "account_id"]) != account.id -> {:error, :copied_customer_account_mismatch}
          true -> {:ok, customer}
        end

      {:error, {404, _}} ->
        {:error, :stripe_customer_copy_required}

      error ->
        error
    end
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
        (subscription["default_tax_rates"] || []) != [] or (subscription["discounts"] || []) != [] ->
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

  # The copy changes the IDs of payment methods. The customer default comes
  # along with the copy, but a payment method set on the subscription itself
  # needs its new ID from Stripe's mapping file.
  defp payment_params(source_customer, customer, subscription, opts) do
    override = subscription["default_payment_method"] || subscription["default_source"]
    paid? = Enum.any?(subscription["items"]["data"], &((&1["price"]["unit_amount"] || 0) > 0))

    cond do
      override != nil and override != default_payment(source_customer) ->
        mapped_payment(override, customer, Keyword.get(opts, :payment_method_map, %{}))

      paid? and subscription["collection_method"] == "charge_automatically" and default_payment(customer) == nil ->
        {:error, :destination_payment_method_required}

      true ->
        {:ok, %{}}
    end
  end

  defp mapped_payment(source_id, customer, payment_method_map) do
    {param, path} =
      case payment_method_map[source_id] do
        "pm_" <> _ = id -> {"default_payment_method", "payment_methods/#{id}"}
        id when is_binary(id) -> {"default_source", "customers/#{customer["id"]}/sources/#{id}"}
        nil -> {nil, nil}
      end

    with true <- param != nil || {:error, {:payment_method_mapping_required, source_id}},
         {:ok, payment} <- get(path),
         true <- payment["customer"] == customer["id"] || {:error, {:payment_method_not_on_customer, payment["id"]}} do
      {:ok, %{param => payment["id"]}}
    end
  end

  defp default_payment(customer) do
    get_in(customer, ["invoice_settings", "default_payment_method"]) || customer["default_source"]
  end

  defp create_and_apply(account_id, plan, opts) do
    account = Database.fetch_account!(account_id)

    with {:ok, current} <- build_plan(account, opts),
         true <- current == plan || {:error, :billing_plan_changed},
         {:ok, subscription} <- find_or_create(plan),
         true <- subscription["status"] in ["active", "trialing"] || {:error, {:subscription_status, subscription["status"]}},
         {:ok, _account} <- Database.put_customer_id(account, plan["customer_id"]),
         {:ok, account} <- EventHandler.sync_region_transfer_subscription(account_id, subscription),
         state = Map.merge(account.metadata.region_transfer, %{"status" => "ready", "destination_subscription_id" => subscription["id"]}),
         {:ok, _account} <- Database.put_state(account, state),
         :ok <- unlink_customer(plan["replace_customer_id"]) do
      IO.puts("Created #{subscription["id"]}. It renews on #{format_time(plan["renews_at"])}.")
      {:ok, subscription["id"]}
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
         subscription["trial_end"] == plan["renews_at"] and Enum.sort(actual) == Enum.sort(expected),
       do: {:ok, subscription},
       else: {:error, {:destination_subscription_conflict, subscription["id"]}}
  end

  # A customer created here by hand would otherwise still name the account,
  # and its webhooks would change it.
  defp unlink_customer(nil), do: :ok

  defp unlink_customer(customer_id) do
    with {:ok, _customer} <- request(:post, "customers/#{customer_id}", URI.encode_query(%{"metadata[account_id]" => ""})) do
      :ok
    end
  end

  # Allows a subscription that a partial earlier run canceled, but not one that
  # changed or appeared after the export.
  defp unchanged_since_export(open, snapshot) do
    exported = Map.new(snapshot["subscriptions"], &{&1["id"], billing_terms(&1)})

    if Enum.all?(open, &(exported[&1["id"]] == billing_terms(&1))),
      do: :ok,
      else: {:error, :source_billing_changed}
  end

  defp billing_terms(subscription) do
    items = Enum.map(subscription["items"]["data"], &{get_in(&1, ["price", "id"]), &1["quantity"]})
    {subscription["current_period_end"], Enum.sort(items)}
  end

  # Canceling turns off the reminders and collection of open invoices. The
  # customer still owes them in the source Stripe account.
  defp keep_collecting_invoices(customer_id) do
    with {:ok, invoices} <- list("invoices", customer: customer_id, status: "open"),
         {:ok, _invoices} <- map_while(invoices, &resume_collection/1) do
      :ok
    end
  end

  defp resume_collection(invoice) do
    request(:post, "invoices/#{invoice["id"]}", URI.encode_query(%{"auto_advance" => true}))
  end

  defp cancel_all(subscriptions) do
    Enum.reduce_while(subscriptions, :ok, fn subscription, :ok ->
      case request(:delete, "subscriptions/#{subscription["id"]}?invoice_now=false&prorate=false") do
        {:ok, _subscription} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp destination_snapshot(account) do
    case account.metadata.region_transfer do
      %{"status" => status, "snapshot" => snapshot} when status in ["pending", "ready"] ->
        if snapshot["source_region"] != region(), do: {:ok, snapshot}, else: {:error, :run_in_destination}

      _state ->
        {:error, :billing_snapshot_missing}
    end
  end

  defp source_snapshot(account) do
    case account.metadata.region_transfer do
      %{"status" => "exported", "snapshot" => %{"source_region" => region} = snapshot} ->
        if region == region(), do: {:ok, snapshot}, else: {:error, :run_in_source}

      %{"status" => "source_canceled"} ->
        {:error, :source_billing_canceled}

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
    Billing of customer #{plan["customer_id"]} in Stripe account #{plan["destination_stripe_account_id"]}
      Replaces subscription #{plan["source_subscription_id"]} of Stripe account #{plan["source_stripe_account_id"]}
      Renews on #{format_time(plan["renews_at"])}, with no charge until then
    """)

    for item <- plan["items"] do
      IO.puts("  #{item["quantity"]} x #{item["product"]} (#{item["price"]}, #{item["unit_amount"]} #{currency()})")
    end

    if plan["open_invoice_ids"] != [] do
      IO.puts("  Leaves open invoices #{Enum.join(plan["open_invoice_ids"], ", ")} to be paid in the source Stripe account")
    end

    if plan["replace_customer_id"] do
      IO.puts("  Unlinks customer #{plan["replace_customer_id"]} from the account")
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
