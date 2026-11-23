defmodule Portal.Ops.RegionTransfer.BillingTest do
  use Portal.DataCase, async: true
  import ExUnit.CaptureIO
  import Plug.Conn
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  alias Portal.Billing.EventHandler
  alias Portal.Mocks.Stripe
  alias Portal.Ops.RegionTransfer

  @container_url "https://transfers.example.test/transfers"
  @customer_id "cus_original"
  @source_account "acct_us"
  @destination_account "acct_eu"

  setup do
    Portal.Config.put_env_override(:data_residency_region, :us)

    account =
      account_fixture(%{metadata: %{stripe: %{customer_id: @customer_id, product_name: "Team", subscription_id: "sub_us"}}})

    admin_actor_fixture(account: account)
    renews_at = System.os_time(:second) + 10 * 86_400

    source_subscription = %{
      "id" => "sub_us",
      "object" => "subscription",
      "customer" => @customer_id,
      "status" => "active",
      "collection_method" => "charge_automatically",
      "current_period_end" => renews_at,
      "trial_end" => nil,
      "cancel_at_period_end" => false,
      "metadata" => %{"seats_note" => "kept"},
      "automatic_tax" => %{"enabled" => false},
      "items" => %{
        "has_more" => false,
        "data" => [
          %{"id" => "si_us", "quantity" => 7, "price" => price("price_us_team", "usd", "prod_us_team")}
        ]
      }
    }

    stripe = start_supervised!({Agent, fn -> %{requests: [], subscriptions: []} end})
    store = stub_storage()

    %{
      account: account,
      renews_at: renews_at,
      source_subscription: source_subscription,
      stripe: stripe,
      store: store
    }
  end

  defp paid_up(ctx), do: stub_source_stripe(ctx, invoices: [%{"id" => "in_paid", "status" => "paid"}])

  defp initiate!(account) do
    capture_io(fn -> {:ok, _manifest} = RegionTransfer.initiate(account.id, confirm: false) end)
  end

  # Runs initiate/2 in the US and leaves the EU database without the account,
  # as two cells would be.
  defp move_to_eu(%{account: account} = ctx, opts \\ []) do
    paid_up(ctx)
    initiate!(account)
    Repo.delete!(reload(account))
    Portal.Config.put_env_override(:data_residency_region, :eu)
    stub_destination_stripe(ctx, opts)
  end

  describe "initiate/2" do
    test "refuses while the customer owes anything", %{account: account, store: store} = ctx do
      stub_source_stripe(ctx, invoices: [%{"id" => "in_sent", "status" => "open", "collection_method" => "send_invoice"}])

      assert {:error, {:billing_outstanding, ["in_sent"]}} = RegionTransfer.initiate(account.id, confirm: false)
      refute reload(account).is_disabled
      assert Agent.get(store, & &1) == %{}
    end

    test "leaves the account enabled when Stripe fails", %{account: account} do
      Req.Test.stub(Portal.Billing.Stripe.APIClient, &send_resp(&1, 500, ""))

      assert {:error, :retry_later} = RegionTransfer.initiate(account.id, confirm: false)
      refute reload(account).is_disabled
    end

    test "exports the account and cancels its subscription at period end", %{account: account, stripe: stripe} = ctx do
      paid_up(ctx)

      output = capture_io(fn -> assert {:ok, _manifest} = RegionTransfer.initiate(account.id, confirm: false) end)
      assert output =~ "copy Stripe customer #{@customer_id}"

      account = reload(account)
      assert account.is_disabled
      assert %{"status" => "exported", "cancel_scheduled" => ["sub_us"]} = account.metadata.region_transfer
      assert [{_key, %{"cancel_at_period_end" => "true"}}] = posts(stripe, "/v1/subscriptions/sub_us")
    end

    test "runs again after the cancel was scheduled", %{account: account} = ctx do
      paid_up(ctx)
      initiate!(account)

      scheduled = Map.merge(ctx.source_subscription, %{"cancel_at_period_end" => true, "cancel_at" => ctx.renews_at})
      stub_source_stripe(%{ctx | source_subscription: scheduled}, invoices: [])
      initiate!(account)

      [subscription] = reload(account).metadata.region_transfer["snapshot"]["subscriptions"]
      assert subscription["cancel_at_period_end"] == false
      assert subscription["cancel_at"] == nil
    end
  end

  describe "complete/2" do
    test "imports, moves billing and enables the account", %{account: account, stripe: stripe} = ctx do
      move_to_eu(ctx)

      output = capture_io(fn -> assert {:ok, _enabled} = RegionTransfer.complete(account.id, confirm: false) end)
      assert output =~ "7 x Team (price_eu_team"

      [{key, params}] = posts(stripe, "/v1/subscriptions")
      assert params["customer"] == @customer_id
      assert params["items[0][price]"] == "price_eu_team"
      assert params["items[0][quantity]"] == "7"
      assert params["billing_cycle_anchor"] == to_string(ctx.renews_at)
      assert params["proration_behavior"] == "none"
      refute Map.has_key?(params, "trial_end")
      assert params["metadata[seats_note]"] == "kept"
      assert [key] = key
      assert key =~ "region-transfer-sub_us-"

      account = reload(account)
      refute account.is_disabled
      assert account.metadata.stripe.subscription_id == "sub_eu_1"
      assert account.metadata.stripe.subscription_status == "active"
    end

    test "finds a copied customer that got a new ID", %{account: account, stripe: stripe} = ctx do
      copied = customer("cus_copied", %{"account_id" => account.id})
      move_to_eu(ctx, customer: :missing, search: [copied], responses: %{"/v1/customers/cus_copied" => copied})

      capture_io(fn -> assert {:ok, _account} = RegionTransfer.complete(account.id, confirm: false) end)

      assert [{_key, %{"customer" => "cus_copied"}}] = posts(stripe, "/v1/subscriptions")
      assert reload(account).metadata.stripe.customer_id == "cus_copied"
    end

    test "creates a customer when none was copied", %{account: account, stripe: stripe} = ctx do
      move_to_eu(ctx, customer: :missing)

      output = capture_io(fn -> assert {:ok, _account} = RegionTransfer.complete(account.id, confirm: false) end)
      assert output =~ "a new customer"
      assert output =~ "no payment method"

      assert [{[key], customer}] = posts(stripe, "/v1/customers")
      assert key == "region-transfer-customer-sub_us"
      assert customer["metadata[account_id]"] == account.id
      assert [{_key, %{"customer" => "cus_created"}}] = posts(stripe, "/v1/subscriptions")
      assert reload(account).metadata.stripe.customer_id == "cus_created"
    end

    test "asks which customer when more than one names the account", %{account: account} = ctx do
      a = customer("cus_a", %{"account_id" => account.id})
      b = customer("cus_b", %{"account_id" => account.id})
      move_to_eu(ctx, customer: :missing, search: [a, b], responses: %{"/v1/customers/cus_b" => b})

      capture_io(fn ->
        assert {:error, {:multiple_customers, ["cus_a", "cus_b"]}} = RegionTransfer.complete(account.id, confirm: false)
      end)

      capture_io(fn -> assert {:ok, _account} = RegionTransfer.complete(account.id, confirm: false, customer: "cus_b") end)
      assert reload(account).metadata.stripe.customer_id == "cus_b"
    end

    test "runs again after an error with the option it asks for", %{account: account} = ctx do
      eur = Map.put(price("price_eu_team", "eur", "prod_test_team"), "unit_amount", 460)
      move_to_eu(ctx, prices: [eur])

      capture_io(fn ->
        assert {:error, {:price_mapping_required, "price_us_team", []}} = RegionTransfer.complete(account.id, confirm: false)
      end)

      assert reload(account).is_disabled

      capture_io(fn ->
        assert {:ok, _account} =
                 RegionTransfer.complete(account.id, confirm: false, price_map: %{"price_us_team" => "price_eu_team"})
      end)

      refute reload(account).is_disabled
    end
  end

  describe "rollback/2" do
    test "renews the subscription again and enables the account", %{account: account, stripe: stripe} = ctx do
      paid_up(ctx)
      initiate!(account)

      assert {:ok, enabled} = RegionTransfer.rollback(account.id, confirm: false)
      refute enabled.is_disabled
      refute Map.has_key?(reload(account).metadata.region_transfer, "cancel_scheduled")
      assert [_scheduled, {_key, %{"cancel_at_period_end" => "false"}}] = posts(stripe, "/v1/subscriptions/sub_us")
    end
  end

  describe "migrate/2" do
    setup ctx do
      Portal.Config.put_env_override(:data_residency_region, :eu)
      stub_destination_stripe(ctx)
      %{account: pending_transfer(ctx)}
    end

    test "finds the subscription of an earlier run instead of creating another", %{account: account, stripe: stripe} do
      capture_io(fn -> assert {:ok, "sub_eu_1"} = RegionTransfer.migrate_billing(account.id, confirm: false) end)
      capture_io(fn -> assert {:ok, "sub_eu_1"} = RegionTransfer.migrate_billing(account.id, confirm: false) end)
      assert length(posts(stripe, "/v1/subscriptions")) == 1
    end

    test "refuses a subscription it did not create", %{account: account, stripe: stripe} do
      Agent.update(stripe, &%{&1 | subscriptions: [%{"id" => "sub_other", "metadata" => %{}, "items" => %{"data" => []}}]})

      capture_io(fn ->
        assert {:error, {:destination_subscription_conflict, "sub_other"}} =
                 RegionTransfer.migrate_billing(account.id, confirm: false)
      end)
    end

    test "refuses a copied customer of another account", %{account: account} = ctx do
      stub_destination_stripe(ctx, customer: customer(@customer_id, %{"account_id" => Ecto.UUID.generate()}))

      assert {:error, {:customer_account_mismatch, @customer_id}} = RegionTransfer.plan_billing(account.id)
    end

    test "stops on unsettled invoices", %{account: account} do
      put_snapshot(account, &Map.put(&1, "unsettled_invoice_ids", ["in_open"]))

      assert {:error, {:unsettled_invoices, ["in_open"]}} = RegionTransfer.plan_billing(account.id)
    end

    test "uses the new ID of a payment method set on the subscription", %{account: account, stripe: stripe} do
      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], &Map.put(&1, "default_payment_method", "pm_old"))
      end)

      assert capture_io(fn -> RegionTransfer.plan_billing(account.id) end) =~ "no payment method"

      capture_io(fn ->
        assert {:ok, _id} =
                 RegionTransfer.migrate_billing(account.id, confirm: false, payment_method_map: %{"pm_old" => "pm_new"})
      end)

      assert [{_key, %{"default_payment_method" => "pm_new"}}] = posts(stripe, "/v1/subscriptions")
    end

    test "keeps a real trial a trial until the same date", %{account: account, stripe: stripe} = ctx do
      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], &Map.put(&1, "status", "trialing"))
      end)

      capture_io(fn -> assert {:ok, "sub_eu_1"} = RegionTransfer.migrate_billing(account.id, confirm: false) end)

      [{_key, params}] = posts(stripe, "/v1/subscriptions")
      refute Map.has_key?(params, "billing_cycle_anchor")
      assert params["trial_end"] == to_string(ctx.renews_at)
    end

    test "moves invoice billing", %{account: account, stripe: stripe} = ctx do
      stub_destination_stripe(ctx, customer: customer(@customer_id, %{"account_id" => account.id}, nil))

      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], fn subscription ->
          Map.merge(subscription, %{
            "collection_method" => "send_invoice",
            "days_until_due" => 30,
            "description" => "PO 1234",
            "payment_settings" => %{"payment_method_types" => ["customer_balance"], "payment_method_options" => nil}
          })
        end)
      end)

      output = capture_io(fn -> assert {:ok, "sub_eu_1"} = RegionTransfer.migrate_billing(account.id, confirm: false) end)
      refute output =~ "no payment method"

      [{_key, params}] = posts(stripe, "/v1/subscriptions")
      assert params["collection_method"] == "send_invoice"
      assert params["days_until_due"] == "30"
      assert params["description"] == "PO 1234"
      assert params["payment_settings[payment_method_types][0]"] == "customer_balance"
      refute Map.has_key?(params, "payment_behavior")
    end

    test "carries a coupon over to the one with the same name and terms", %{account: account, stripe: stripe} = ctx do
      free = %{"name" => "Customer staging environment", "percent_off" => 100.0, "amount_off" => nil, "duration" => "forever", "duration_in_months" => nil, "valid" => true}

      stub_destination_stripe(ctx,
        customer: customer(@customer_id, %{"account_id" => account.id}, nil),
        responses: %{
          "/v1/coupons" =>
            list([Map.merge(free, %{"id" => "coupon_eu_free"}), Map.merge(free, %{"id" => "coupon_eu_half", "percent_off" => 50.0})])
        }
      )

      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], fn subscription ->
          Map.merge(subscription, %{"discount" => %{"id" => "di_us", "coupon" => Map.put(free, "id", "coupon_us_free")}, "discounts" => ["di_us"]})
        end)
      end)

      output = capture_io(fn -> assert {:ok, "sub_eu_1"} = RegionTransfer.migrate_billing(account.id, confirm: false) end)
      assert output =~ "Coupon Customer staging environment (coupon_eu_free)"
      refute output =~ "no payment method"
      assert [{_key, %{"coupon" => "coupon_eu_free"}}] = posts(stripe, "/v1/subscriptions")
    end

    test "needs a coupon map when no coupon matches", %{account: account} = ctx do
      stub_destination_stripe(ctx, responses: %{"/v1/coupons" => list([])})
      coupon = %{"id" => "coupon_us", "name" => "Legacy", "percent_off" => 10.0, "duration" => "forever", "valid" => true}

      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], &Map.merge(&1, %{"discount" => %{"coupon" => coupon}, "discounts" => ["di_us"]}))
      end)

      assert {:error, {:coupon_mapping_required, "coupon_us", []}} = RegionTransfer.plan_billing(account.id)

      stub_destination_stripe(ctx, responses: %{"/v1/coupons" => list([Map.put(coupon, "id", "coupon_eu")])})

      capture_io(fn ->
        assert {:ok, %{"params" => %{"coupon" => "coupon_eu"}}} =
                 RegionTransfer.plan_billing(account.id, coupon_map: %{"coupon_us" => "coupon_eu"})
      end)
    end

    test "refuses a repeating coupon", %{account: account} do
      coupon = %{"id" => "coupon_us", "duration" => "repeating", "duration_in_months" => 3}

      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], &Map.merge(&1, %{"discount" => %{"coupon" => coupon}, "discounts" => ["di_us"]}))
      end)

      assert {:error, {:coupon_requires_review, "coupon_us"}} = RegionTransfer.plan_billing(account.id)
    end

    test "refuses invoice settings of the source Stripe account", %{account: account} do
      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], fn subscription ->
          Map.put(subscription, "invoice_settings", %{"account_tax_ids" => ["txi_us"], "issuer" => %{"type" => "self"}})
        end)
      end)

      assert {:error, {:subscription_requires_review, "sub_us"}} = RegionTransfer.plan_billing(account.id)
    end
  end

  describe "enable/2" do
    test "refuses a transfer that did not record the billing", %{account: account} do
      account |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Region transfer in progress") |> Repo.update!()

      assert {:error, :billing_snapshot_missing} = RegionTransfer.enable(account.id, confirm: false)
      assert {:ok, _account} = RegionTransfer.enable(account.id, confirm: false, billing: :skip, notify: false)
    end
  end

  describe "billing webhooks during a transfer" do
    setup %{account: account} do
      account |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Region transfer in progress") |> Repo.update!()
      :ok
    end

    test "do not end it", %{account: account} do
      {product, _price, subscription} = Stripe.build_all(:team, @customer_id, 5)
      customer = Stripe.build_customer(id: @customer_id, metadata: %{"account_id" => account.id})
      Stripe.stub(Stripe.fetch_customer_endpoint(customer) ++ Stripe.fetch_product_endpoint(product))

      assert {:ok, _event} = EventHandler.handle_event(Stripe.build_event("customer.subscription.created", subscription))
      assert %{is_disabled: true, disabled_reason: "Region transfer in progress"} = reload(account)

      deleted = Map.put(subscription, "status", "canceled")
      assert {:ok, _event} = EventHandler.handle_event(Stripe.build_event("customer.subscription.deleted", deleted))
      assert %{is_disabled: true, disabled_reason: "Region transfer in progress"} = reload(account)
    end
  end

  defp pending_transfer(%{account: account, source_subscription: subscription}) do
    snapshot = %{
      "source_region" => "us",
      "source_stripe_account_id" => @source_account,
      "customer" => customer(@customer_id, %{"account_id" => account.id}),
      "subscriptions" => [put_in(subscription, ["items", "data", Access.at(0), "price", "product"], product("prod_us_team"))],
      "unsettled_invoice_ids" => [],
      "open_invoice_ids" => [],
      "pending_invoice_item_ids" => []
    }

    account
    |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Region transfer in progress")
    |> Repo.update!()
    |> put_state(%{"status" => "pending", "snapshot" => snapshot})
  end

  defp put_snapshot(account, fun) do
    state = account.metadata.region_transfer
    put_state(account, %{state | "snapshot" => fun.(state["snapshot"])})
  end

  defp put_state(account, state) do
    account
    |> Ecto.Changeset.cast(%{metadata: %{region_transfer: state}}, [])
    |> Ecto.Changeset.cast_embed(:metadata)
    |> Repo.update!()
  end

  defp stub_source_stripe(%{account: account, stripe: stripe, source_subscription: subscription}, opts) do
    stub_stripe(stripe, %{
      "/v1/account" => %{"id" => @source_account},
      "/v1/customers/#{@customer_id}" => customer(@customer_id, %{"account_id" => account.id}),
      "/v1/subscriptions" => list([subscription]),
      "/v1/products/prod_us_team" => product("prod_us_team"),
      "/v1/invoices" =>
        list(Keyword.get(opts, :invoices, [%{"id" => "in_paid", "status" => "paid", "collection_method" => "charge_automatically"}])),
      "/v1/invoiceitems" => list([])
    })
  end

  defp stub_destination_stripe(%{account: account, stripe: stripe}, opts \\ []) do
    responses = %{
      "/v1/account" => %{"id" => @destination_account},
      "/v1/customers/#{@customer_id}" => Keyword.get(opts, :customer, customer(@customer_id, %{"account_id" => account.id})),
      "/v1/prices" => list(Keyword.get(opts, :prices, [price("price_eu_team", "eur", "prod_test_team")])),
      "/v1/products/prod_test_team" => Stripe.build_product(id: "prod_test_team", name: "Team"),
      "/v1/customers/search" => list(Keyword.get(opts, :search, []))
    }

    stub_stripe(stripe, Map.merge(responses, Keyword.get(opts, :responses, %{})))
  end

  # Subscriptions that POST /v1/subscriptions creates show up in later lists.
  defp stub_stripe(stripe, responses) do
    Req.Test.stub(Portal.Billing.Stripe.APIClient, fn conn ->
      {:ok, body, conn} = read_body(conn)
      key = get_req_header(conn, "idempotency-key")

      Agent.update(stripe, fn state ->
        request = %{method: conn.method, path: conn.request_path, query: conn.query_string, body: body, key: key}
        %{state | requests: state.requests ++ [request]}
      end)

      respond(conn, stripe, responses, URI.decode_query(body))
    end)
  end

  defp respond(%{method: "POST", request_path: "/v1/subscriptions"} = conn, stripe, responses, params) do
    price = responses["/v1/prices"]["data"] |> Enum.find(&(&1["id"] == params["items[0][price]"]))

    subscription =
      Agent.get_and_update(stripe, fn state ->
        subscription = %{
          "id" => "sub_eu_#{length(state.subscriptions) + 1}",
          "customer" => params["customer"],
          "status" => if(params["trial_end"], do: "trialing", else: "active"),
          "trial_end" => params["trial_end"] && String.to_integer(params["trial_end"]),
          "current_period_end" => String.to_integer(params["billing_cycle_anchor"] || params["trial_end"]),
          "metadata" =>
            for({"metadata[" <> key, value} <- params, into: %{}, do: {String.trim_trailing(key, "]"), value}),
          "items" => %{
            "data" => [
              %{"quantity" => String.to_integer(params["items[0][quantity]"]), "price" => %{price | "product" => "prod_test_team"}}
            ]
          }
        }

        {subscription, %{state | subscriptions: state.subscriptions ++ [subscription]}}
      end)

    Req.Test.json(conn, subscription)
  end

  defp respond(%{method: "POST", request_path: "/v1/customers"} = conn, _stripe, _responses, params) do
    Req.Test.json(conn, Map.merge(customer("cus_created", %{}, nil), %{"name" => params["name"], "email" => params["email"]}))
  end

  defp respond(%{method: "GET", request_path: "/v1/subscriptions"} = conn, stripe, responses, _params) do
    case Agent.get(stripe, & &1.subscriptions) do
      [] -> Req.Test.json(conn, responses["/v1/subscriptions"] || list([]))
      created -> Req.Test.json(conn, list(created))
    end
  end

  defp respond(%{method: method, request_path: path} = conn, _stripe, responses, _params)
       when method in ["POST", "DELETE"] do
    Req.Test.json(conn, Map.get(responses, path, %{"id" => Path.basename(path)}))
  end

  defp respond(%{request_path: path} = conn, _stripe, responses, _params) do
    conn = fetch_query_params(conn)
    status = conn.query_params["status"]

    case Map.fetch(responses, path) do
      {:ok, %{"object" => "list", "data" => data} = response} when status not in [nil, "all"] ->
        Req.Test.json(conn, %{response | "data" => Enum.filter(data, &(&1["status"] == status))})

      {:ok, :missing} -> conn |> put_status(404) |> Req.Test.json(%{"error" => %{"code" => "resource_missing"}})
      {:ok, response} -> Req.Test.json(conn, response)
      :error -> conn |> put_status(404) |> Req.Test.json(%{"error" => %{"message" => "no stub for #{path}"}})
    end
  end

  defp requests(stripe), do: Agent.get(stripe, & &1.requests)

  defp posts(stripe, path) do
    for %{method: "POST", path: ^path} = request <- requests(stripe), do: {request.key, URI.decode_query(request.body)}
  end

  defp list(data), do: %{"object" => "list", "has_more" => false, "data" => data}

  defp customer(id, metadata, default_payment_method \\ "pm_card") do
    %{
      "id" => id,
      "object" => "customer",
      "livemode" => false,
      "balance" => 0,
      "discount" => nil,
      "tax_exempt" => "none",
      "default_source" => nil,
      "invoice_settings" => %{"default_payment_method" => default_payment_method},
      "metadata" => metadata
    }
  end

  defp price(id, currency, product_id) do
    %{
      "id" => id,
      "currency" => currency,
      "unit_amount" => 500,
      "billing_scheme" => "per_unit",
      "tax_behavior" => "exclusive",
      "transform_quantity" => nil,
      "recurring" => %{"interval" => "month", "interval_count" => 1, "usage_type" => "licensed"},
      "product" => if(currency == "eur", do: product(product_id), else: product_id)
    }
  end

  defp product(id), do: %{"id" => id, "name" => "Team", "metadata" => Stripe.team_metadata()}

  defp reload(account), do: Repo.get!(Portal.Account, account.id)

  defp stub_storage do
    Portal.Config.put_env_override(:region_transfer_outbox_url, @container_url)
    Portal.Config.put_env_override(:region_transfer_inbox_url, @container_url)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{"access_token" => "storage-token", "expires_on" => "4102444800"})
    end)

    store = start_supervised!({Agent, fn -> %{} end}, id: :store)

    Req.Test.stub(RegionTransfer.Storage, fn
      %{method: "PUT"} = conn ->
        {:ok, body, conn} = read_body(conn)
        Agent.update(store, &Map.put(&1, conn.request_path, body))
        send_resp(conn, 201, "")

      %{method: "GET"} = conn ->
        case Agent.get(store, &Map.fetch(&1, conn.request_path)) do
          {:ok, body} -> send_resp(conn, 200, body)
          :error -> send_resp(conn, 404, "")
        end
    end)

    store
  end

end
