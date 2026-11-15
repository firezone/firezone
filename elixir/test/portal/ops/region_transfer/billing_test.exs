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

  describe "export" do
    test "records the billing before it disables the account", %{account: account, store: store} = ctx do
      stub_source_stripe(ctx)

      capture_io(fn -> assert {:ok, _manifest} = RegionTransfer.export(account.id, confirm: false) end)

      account = reload(account)
      assert account.is_disabled
      assert %{"status" => "exported", "snapshot" => snapshot} = account.metadata.region_transfer
      assert snapshot["source_region"] == "us"
      assert snapshot["source_stripe_account_id"] == @source_account
      assert [%{"id" => "sub_us"}] = snapshot["subscriptions"]
      assert snapshot["unsettled_invoice_ids"] == ["in_open"]

      manifest = store |> blob(account.id, "manifest.json") |> Jason.decode!()
      assert is_binary(manifest["billing_checksum"])
      assert blob(store, account.id, "billing.json")
    end

    test "leaves the account enabled when Stripe fails", %{account: account} do
      Req.Test.stub(Portal.Billing.Stripe.APIClient, &send_resp(&1, 500, ""))

      capture_io(fn -> assert {:error, :retry_later} = RegionTransfer.export(account.id, confirm: false) end)

      refute reload(account).is_disabled
    end
  end

  describe "import, migrate and enable" do
    test "recreate the subscription with the original renewal date", %{account: account} = ctx do
      stub_source_stripe(ctx)
      capture_io(fn -> {:ok, _manifest} = RegionTransfer.export(account.id, confirm: false) end)
      Repo.delete!(account)

      Portal.Config.put_env_override(:data_residency_region, :eu)
      capture_io(fn -> assert {:ok, _manifest} = RegionTransfer.import(account.id, confirm: false) end)
      assert %{"status" => "pending"} = reload(account).metadata.region_transfer
      assert {:error, :billing_not_migrated} = RegionTransfer.enable(account.id, confirm: false)

      stub_destination_stripe(ctx)
      account |> reload() |> put_snapshot(&Map.put(&1, "unsettled_invoice_ids", []))

      output = capture_io(fn -> assert {:ok, "sub_eu_1"} = RegionTransfer.migrate_billing(account.id, confirm: false) end)
      assert output =~ "7 x Team (price_eu_team"

      [{headers, params}] = posts(ctx.stripe, "/v1/subscriptions")
      assert params["customer"] == @customer_id
      assert params["items[0][price]"] == "price_eu_team"
      assert params["items[0][quantity]"] == "7"
      assert params["trial_end"] == to_string(ctx.renews_at)
      assert params["proration_behavior"] == "none"
      assert params["metadata[region_transfer_prepaid_until]"] == to_string(ctx.renews_at)
      assert params["metadata[seats_note]"] == "kept"
      assert [key] = headers
      assert key =~ "region-transfer-sub_us-"

      account = reload(account)
      assert account.is_disabled
      assert account.metadata.stripe.subscription_id == "sub_eu_1"
      assert account.metadata.stripe.subscription_status == "trialing"
      assert is_nil(account.metadata.stripe.trial_ends_at)
      assert %{"status" => "ready", "destination_subscription_id" => "sub_eu_1"} = account.metadata.region_transfer

      assert {:ok, enabled} = RegionTransfer.enable(account.id, confirm: false)
      refute enabled.is_disabled
    end
  end

  describe "migrate/2" do
    setup ctx do
      Portal.Config.put_env_override(:data_residency_region, :eu)
      stub_destination_stripe(ctx)
      account = pending_transfer(ctx)
      %{account: account}
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

    test "waits for the Stripe customer copy", %{account: account} = ctx do
      stub_destination_stripe(ctx, customer: :missing)

      assert {:error, :stripe_customer_copy_required} = RegionTransfer.plan_billing(account.id)
    end

    test "refuses a copied customer of another account", %{account: account} = ctx do
      stub_destination_stripe(ctx, customer: customer("cus_original", %{"account_id" => Ecto.UUID.generate()}))

      assert {:error, :copied_customer_account_mismatch} = RegionTransfer.plan_billing(account.id)
    end

    test "needs a payment method to charge", %{account: account} = ctx do
      stub_destination_stripe(ctx, customer: customer(@customer_id, %{"account_id" => account.id}, nil))

      assert {:error, :destination_payment_method_required} = RegionTransfer.plan_billing(account.id)
    end

    test "needs a price map when no price matches", %{account: account} = ctx do
      stub_destination_stripe(ctx, prices: [Map.put(price("price_eu_team", "eur", "prod_test_team"), "unit_amount", 460)])

      assert {:error, {:price_mapping_required, "price_us_team", []}} = RegionTransfer.plan_billing(account.id)

      capture_io(fn ->
        assert {:ok, plan} = RegionTransfer.plan_billing(account.id, price_map: %{"price_us_team" => "price_eu_team"})
        assert [%{"price" => "price_eu_team", "quantity" => 7}] = plan["items"]
      end)
    end

    test "stops on unsettled invoices", %{account: account} do
      account |> put_snapshot(&Map.put(&1, "unsettled_invoice_ids", ["in_open"]))

      assert {:error, {:unsettled_invoices, ["in_open"]}} = RegionTransfer.plan_billing(account.id)
    end

    test "needs the new ID of a payment method set on the subscription", %{account: account} = ctx do
      put_snapshot(account, fn snapshot ->
        update_in(snapshot, ["subscriptions", Access.at(0)], &Map.put(&1, "default_payment_method", "pm_old"))
      end)

      assert {:error, {:payment_method_mapping_required, "pm_old"}} = RegionTransfer.plan_billing(account.id)

      Agent.update(ctx.stripe, &Map.put(&1, :payment_methods, %{"pm_new" => %{"id" => "pm_new", "customer" => "cus_other"}}))

      assert {:error, {:payment_method_not_on_customer, "pm_new"}} =
               RegionTransfer.plan_billing(account.id, payment_method_map: %{"pm_old" => "pm_new"})
    end

    test "replaces a customer created in the destination by hand", %{account: account, stripe: stripe} do
      account
      |> Ecto.Changeset.cast(%{metadata: %{stripe: %{customer_id: "cus_by_hand"}}}, [])
      |> Ecto.Changeset.cast_embed(:metadata)
      |> Repo.update!()

      assert {:error, {:unexpected_customer, "cus_by_hand"}} = RegionTransfer.plan_billing(account.id)

      capture_io(fn ->
        assert {:ok, "sub_eu_1"} =
                 RegionTransfer.migrate_billing(account.id, confirm: false, replace_customer: "cus_by_hand")
      end)

      assert reload(account).metadata.stripe.customer_id == @customer_id
      assert [{_headers, %{"metadata[account_id]" => ""}}] = posts(stripe, "/v1/customers/cus_by_hand")
    end
  end

  describe "finish_source_billing/2" do
    setup ctx do
      stub_source_stripe(ctx)
      capture_io(fn -> {:ok, _manifest} = RegionTransfer.export(ctx.account.id, confirm: false) end)
      :ok
    end

    test "cancels without proration and blocks a rollback", %{account: account, stripe: stripe} do
      capture_io(fn -> assert {:ok, _account} = RegionTransfer.finish_source_billing(account.id, confirm: false) end)

      assert [%{method: "DELETE", query: "invoice_now=false&prorate=false"}] =
               stripe |> requests() |> Enum.filter(&(&1.path == "/v1/subscriptions/sub_us"))

      assert {:error, :source_billing_canceled} = RegionTransfer.enable(account.id, confirm: false)
    end

    test "refuses when the source subscription changed after the export", %{account: account} = ctx do
      changed = put_in(ctx.source_subscription, ["items", "data", Access.at(0), "quantity"], 8)
      stub_source_stripe(%{ctx | source_subscription: changed})

      capture_io(fn ->
        assert {:error, :source_billing_changed} = RegionTransfer.finish_source_billing(account.id, confirm: false)
      end)
    end

    test "refuses in the destination", %{account: account} do
      Portal.Config.put_env_override(:data_residency_region, :eu)

      assert {:error, :run_in_source} = RegionTransfer.finish_source_billing(account.id, confirm: false)
    end
  end

  describe "enable/2" do
    test "refuses a transfer that did not record the billing", %{account: account} do
      account |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Region transfer in progress") |> Repo.update!()

      assert {:error, :billing_snapshot_missing} = RegionTransfer.enable(account.id, confirm: false)
      assert {:ok, _account} = RegionTransfer.enable(account.id, confirm: false, billing: :skip, notify: false)
    end
  end

  describe "export_billing/1 and import_billing/2" do
    test "move the billing of an account exported without it", %{account: account} = ctx do
      stub_source_stripe(ctx)
      account |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Region transfer in progress") |> Repo.update!()

      output = capture_io(fn -> send(self(), RegionTransfer.export_billing(account.id)) end)
      assert_received {:ok, checksum}
      assert output =~ checksum

      Portal.Config.put_env_override(:data_residency_region, :eu)
      assert {:error, {:checksum_mismatch, "billing"}} = RegionTransfer.import_billing(account.id, String.duplicate("0", 64))
      assert :ok = RegionTransfer.import_billing(account.id, checksum)
      assert %{"status" => "pending"} = reload(account).metadata.region_transfer
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

  describe "billing webhooks of a transferred subscription" do
    test "show no trial", %{account: account} do
      {product, _price, subscription} = Stripe.build_all(:team, @customer_id, 5)
      trial_end = System.os_time(:second) + 86_400

      subscription =
        Map.merge(subscription, %{
          "status" => "trialing",
          "trial_end" => trial_end,
          "metadata" => %{"region_transfer_prepaid_until" => to_string(trial_end)}
        })

      customer = Stripe.build_customer(id: @customer_id, metadata: %{"account_id" => account.id})
      Stripe.stub(Stripe.fetch_customer_endpoint(customer) ++ Stripe.fetch_product_endpoint(product))

      assert {:ok, _event} = EventHandler.handle_event(Stripe.build_event("customer.subscription.updated", subscription))
      assert is_nil(reload(account).metadata.stripe.trial_ends_at)
    end
  end

  defp pending_transfer(%{account: account, source_subscription: subscription}) do
    snapshot = %{
      "source_region" => "us",
      "source_stripe_account_id" => @source_account,
      "customer" => customer(@customer_id, %{"account_id" => account.id}),
      "subscriptions" => [put_in(subscription, ["items", "data", Access.at(0), "price", "product"], product("prod_us_team"))],
      "unsettled_invoice_ids" => [],
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

  defp stub_source_stripe(%{account: account, stripe: stripe, source_subscription: subscription}) do
    stub_stripe(stripe, %{
      "/v1/account" => %{"id" => @source_account},
      "/v1/customers/#{@customer_id}" => customer(@customer_id, %{"account_id" => account.id}),
      "/v1/subscriptions" => list([subscription]),
      "/v1/products/prod_us_team" => product("prod_us_team"),
      "/v1/invoices" => list([%{"id" => "in_paid", "status" => "paid"}, %{"id" => "in_open", "status" => "open"}]),
      "/v1/invoiceitems" => list([])
    })
  end

  defp stub_destination_stripe(%{account: account, stripe: stripe}, opts \\ []) do
    responses = %{
      "/v1/account" => %{"id" => @destination_account},
      "/v1/customers/#{@customer_id}" => Keyword.get(opts, :customer, customer(@customer_id, %{"account_id" => account.id})),
      "/v1/prices" => list(Keyword.get(opts, :prices, [price("price_eu_team", "eur", "prod_test_team")])),
      "/v1/products/prod_test_team" => Stripe.build_product(id: "prod_test_team", name: "Team")
    }

    stub_stripe(stripe, responses)
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
          "status" => "trialing",
          "trial_end" => String.to_integer(params["trial_end"]),
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

  defp respond(%{method: "GET", request_path: "/v1/subscriptions"} = conn, stripe, responses, _params) do
    case Agent.get(stripe, & &1.subscriptions) do
      [] -> Req.Test.json(conn, responses["/v1/subscriptions"] || list([]))
      created -> Req.Test.json(conn, list(created))
    end
  end

  defp respond(%{method: "GET", request_path: "/v1/payment_methods/" <> id} = conn, stripe, _responses, _params) do
    case Agent.get(stripe, &get_in(&1, [:payment_methods, id])) do
      nil -> conn |> put_status(404) |> Req.Test.json(%{})
      payment_method -> Req.Test.json(conn, payment_method)
    end
  end

  defp respond(%{method: method, request_path: path} = conn, _stripe, responses, _params)
       when method in ["POST", "DELETE"] do
    Req.Test.json(conn, Map.get(responses, path, %{"id" => Path.basename(path)}))
  end

  defp respond(%{request_path: path} = conn, _stripe, responses, _params) do
    case Map.fetch(responses, path) do
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

  defp blob(store, account_id, name), do: Agent.get(store, &Map.get(&1, "/transfers/#{account_id}/#{name}"))
end
