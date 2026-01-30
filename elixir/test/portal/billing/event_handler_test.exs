defmodule Portal.Billing.EventHandlerTest do
  use Portal.DataCase, async: true

  alias Portal.Billing.EventHandler
  alias Portal.Mocks.Stripe

  import Portal.AccountFixtures

  describe "handle_event/1 with customer.updated" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "updates account with legal_name from customer name", %{account: account} do
      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Updated Legal Name",
          email: "updated@example.com",
          metadata: %{
            "account_id" => account.id
          }
        )

      event = Stripe.build_event("customer.updated", customer)

      # Mock the fetch customer endpoint (called to get account_id from metadata)
      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.legal_name == "Updated Legal Name"
    end

    test "uses account_name from metadata for name but legal_name from customer name", %{
      account: account
    } do
      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Legal Corp Inc",
          email: "updated@example.com",
          metadata: %{
            "account_id" => account.id,
            "account_name" => "Friendly Display Name"
          }
        )

      event = Stripe.build_event("customer.updated", customer)

      # Mock the fetch customer endpoint (called to get account_id from metadata)
      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.name == "Friendly Display Name"
      assert updated_account.legal_name == "Legal Corp Inc"
    end

    test "updates account slug from metadata", %{account: account} do
      original_slug = account.slug

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Same Name",
          email: "updated@example.com",
          metadata: %{
            "account_id" => account.id,
            "account_slug" => "new-custom-slug"
          }
        )

      event = Stripe.build_event("customer.updated", customer)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.slug == "new-custom-slug"
      assert updated_account.slug != original_slug
    end
  end

  describe "handle_event/1 with customer.subscription.deleted" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "disables account when subscription is deleted", %{account: account} do
      subscription = Stripe.subscription_object(account.metadata.stripe.customer_id, %{}, %{}, 1)
      subscription = Map.put(subscription, "status", "canceled")

      event = Stripe.build_event("customer.subscription.deleted", subscription)

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.disabled_at != nil
      assert updated_account.disabled_reason == "Stripe subscription deleted"
    end
  end

  describe "handle_event/1 with customer.created" do
    test "returns error when required metadata is missing" do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Incomplete Corp",
          email: "admin@incomplete.com",
          metadata: %{}
        )

      event = Stripe.build_event("customer.created", customer)

      assert {:error, :missing_custom_metadata} = EventHandler.handle_event(event)
    end

    test "skips account creation when account_id already in metadata" do
      customer_id = "cus_" <> Stripe.random_id()
      existing_account_id = Ecto.UUID.generate()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Existing Corp",
          email: "admin@existing.com",
          metadata: %{
            "account_id" => existing_account_id,
            "company_website" => "existing.com",
            "account_owner_first_name" => "Test",
            "account_owner_last_name" => "User"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      assert {:ok, _event} = EventHandler.handle_event(event)

      # No account should be created
      account = Portal.Repo.get_by(Portal.Account, slug: "existing")
      assert account == nil
    end

    test "creates account with all defaults when metadata is complete" do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "New Corp Inc",
          email: "billing@newcorp.com",
          metadata: %{
            "company_website" => "https://newcorp.com",
            "account_owner_first_name" => "Jane",
            "account_owner_last_name" => "Doe"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      # Mock the update customer endpoint (called to set account_id in Stripe metadata)
      # and the create subscription endpoint
      expectations =
        [{"POST", "/v1/customers/#{customer_id}", 200, customer}] ++
          Stripe.mock_create_subscription_endpoint()

      Stripe.stub(expectations)

      assert {:ok, _event} = EventHandler.handle_event(event)

      # Account should be created
      account = Portal.Repo.get_by(Portal.Account, slug: "newcorp")
      assert account != nil
      assert account.name == "New Corp Inc"
      assert account.legal_name == "New Corp Inc"

      # Email OTP provider should be created
      email_provider = Portal.Repo.get_by(Portal.EmailOTP.AuthProvider, account_id: account.id)
      assert email_provider != nil
      assert email_provider.name == "Email (OTP)"

      # Admin actor should be created
      admin = Portal.Repo.get_by(Portal.Actor, account_id: account.id, type: :account_admin_user)
      assert admin != nil
      assert admin.email == "billing@newcorp.com"
      assert admin.name == "Jane Doe"
    end
  end

  describe "handle_event/1 with subscription active events" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "processes subscription with a single plan product", %{
      account: account,
      customer: customer
    } do
      {product, _price, subscription} =
        Stripe.build_all(:enterprise, account.metadata.stripe.customer_id, 10)

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.disabled_at == nil
    end

    test "processes plan product and ignores adhoc device product", %{
      account: account,
      customer: customer
    } do
      {product, _price, subscription} =
        Stripe.build_all(:enterprise, account.metadata.stripe.customer_id, 10)

      adhoc_price = Stripe.build_price(product: "prod_test_adhoc_device")
      adhoc_item = Stripe.build_subscription_item(price: adhoc_price, quantity: 1)
      subscription = update_in(subscription, ["items", "data"], &[adhoc_item | &1])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.disabled_at == nil
    end

    test "processes plan product and warns on unrecognized product", %{
      account: account,
      customer: customer
    } do
      {product, _price, subscription} =
        Stripe.build_all(:enterprise, account.metadata.stripe.customer_id, 10)

      unknown_price = Stripe.build_price(product: "prod_unknown_xyz")
      unknown_item = Stripe.build_subscription_item(price: unknown_price, quantity: 1)
      subscription = update_in(subscription, ["items", "data"], &[unknown_item | &1])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.disabled_at == nil
    end

    test "returns error when subscription has multiple plan products", %{
      account: account,
      customer: customer
    } do
      {_product1, _price1, subscription} =
        Stripe.build_all(:enterprise, account.metadata.stripe.customer_id, 10)

      team_price = Stripe.build_price(product: "prod_test_team")
      team_item = Stripe.build_subscription_item(price: team_price, quantity: 5)
      subscription = update_in(subscription, ["items", "data"], &[team_item | &1])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:error, :multiple_plan_products} = EventHandler.handle_event(event)
    end

    test "returns error when subscription has no plan products", %{
      account: account,
      customer: customer
    } do
      subscription =
        Stripe.build_subscription(
          customer: account.metadata.stripe.customer_id,
          items: [[price: Stripe.build_price(product: "prod_unknown_xyz"), quantity: 1]]
        )

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:error, :no_plan_product} = EventHandler.handle_event(event)
    end

    test "clears account limit flags when subscription update increases limits", %{
      account: account,
      customer: customer
    } do
      # Set limit flags on the account indicating limits exceeded
      update_account(account, %{
        users_limit_exceeded: true,
        limits: %{users_count: 1}
      })

      # Verify limit flag is set
      account_before = Portal.Repo.get!(Portal.Account, account.id)
      assert account_before.users_limit_exceeded

      # Process subscription update with higher limits
      {product, _price, subscription} =
        Stripe.build_all(:team, account.metadata.stripe.customer_id, 100)

      event = Stripe.build_event("customer.subscription.updated", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      # Limit flags should be cleared after subscription update
      updated = Portal.Repo.get!(Portal.Account, account.id)
      refute Portal.Account.any_limit_exceeded?(updated)
    end

    test "sets account limit flags when subscription update results in exceeded limits", %{
      account: account,
      customer: customer
    } do
      # Create actors to exceed the limit
      Portal.ActorFixtures.actor_fixture(account: account, type: :account_user)
      Portal.ActorFixtures.actor_fixture(account: account, type: :account_user)
      Portal.ActorFixtures.actor_fixture(account: account, type: :account_user)

      # Account starts with no limit flags set
      refute Portal.Account.any_limit_exceeded?(account)

      # Process subscription update with low limits (1 user)
      {product, _price, subscription} =
        Stripe.build_all(:team, account.metadata.stripe.customer_id, 1)

      event = Stripe.build_event("customer.subscription.updated", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      # Limit flags should be set after subscription update
      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.users_limit_exceeded
    end
  end

  describe "handle_event/1 with customer.subscription.paused" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "disables account when subscription is paused", %{account: account, customer: customer} do
      subscription = Stripe.subscription_object(account.metadata.stripe.customer_id, %{}, %{}, 1)
      subscription = Map.put(subscription, "status", "paused")

      event = Stripe.build_event("customer.subscription.paused", subscription)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.disabled_at != nil
      assert updated_account.disabled_reason == "Stripe subscription paused"
    end
  end

  describe "handle_event/1 with customer.subscription.updated (paused)" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "disables account when subscription is paused via update event", %{
      account: account,
      customer: customer
    } do
      subscription = Stripe.subscription_object(account.metadata.stripe.customer_id, %{}, %{}, 1)
      subscription = Stripe.pause_subscription(subscription)

      event = Stripe.build_event("customer.subscription.updated", subscription)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.disabled_at != nil
      assert updated_account.disabled_reason == "Stripe subscription paused"
    end
  end

  describe "handle_event/1 with unknown event type" do
    test "handles unknown event types gracefully" do
      customer = Stripe.build_customer(id: "cus_test123")
      event = Stripe.build_event("some.unknown.event", customer)

      assert {:ok, _event} = EventHandler.handle_event(event)
    end
  end

  describe "handle_event/1 with already processed events" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "skips already processed events", %{account: account} do
      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Updated Name",
          metadata: %{"account_id" => account.id}
        )

      event = Stripe.build_event("customer.updated", customer)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      # Process the event first time
      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.legal_name == "Updated Name"

      # Update the account name back
      update_account(updated_account, %{legal_name: "Original Name"})

      # Process the same event again - should be skipped
      assert {:ok, _event} = EventHandler.handle_event(event)

      # Account should not be updated because event was skipped
      final_account = Portal.Repo.get!(Portal.Account, account.id)
      assert final_account.legal_name == "Original Name"
    end

    test "skips older events based on chronological order", %{account: account} do
      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Newer Name",
          metadata: %{"account_id" => account.id}
        )

      # Create a newer event first
      newer_time = DateTime.utc_now() |> DateTime.to_unix()
      newer_event = Stripe.build_event("customer.updated", customer, newer_time)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      # Process newer event
      assert {:ok, _event} = EventHandler.handle_event(newer_event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.legal_name == "Newer Name"

      # Reset the name
      update_account(updated_account, %{legal_name: "Reset Name"})

      # Now try to process an older event (1 hour older)
      older_customer = Map.put(customer, "name", "Older Name")
      older_time = newer_time - 3600
      # Need a different event ID for the older event
      older_event =
        Stripe.build_event("customer.updated", older_customer, older_time)
        |> Map.put("id", "evt_older_" <> Stripe.random_id())

      # The older event should be skipped
      assert {:ok, _event} = EventHandler.handle_event(older_event)

      # Account should not be updated because event was older
      final_account = Portal.Repo.get!(Portal.Account, account.id)
      assert final_account.legal_name == "Reset Name"
    end
  end

  describe "handle_event/1 with customer.created - slug generation" do
    test "uses account_slug from metadata when provided" do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Slug Test Corp",
          email: "admin@slugtest.com",
          metadata: %{
            "company_website" => "https://slugtest.com",
            "account_owner_first_name" => "Test",
            "account_owner_last_name" => "User",
            "account_slug" => "custom_provided_slug"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      Stripe.stub([
        {"POST", "/v1/customers/#{customer_id}", 200, customer},
        {"POST", "/v1/subscriptions", 200, Stripe.subscription_object(customer_id, %{}, %{}, 1)}
      ])

      assert {:ok, _event} = EventHandler.handle_event(event)

      account = Portal.Repo.get_by(Portal.Account, slug: "custom_provided_slug")
      assert account != nil
    end

    test "extracts slug from company website path when no host" do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Path Test Corp",
          email: "admin@pathtest.com",
          metadata: %{
            "company_website" => "pathtest.com",
            "account_owner_first_name" => "Test",
            "account_owner_last_name" => "User"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      Stripe.stub([
        {"POST", "/v1/customers/#{customer_id}", 200, customer},
        {"POST", "/v1/subscriptions", 200, Stripe.subscription_object(customer_id, %{}, %{}, 1)}
      ])

      assert {:ok, _event} = EventHandler.handle_event(event)

      # The slug should be extracted from the path
      account = Portal.Repo.get_by(Portal.Account, slug: "pathtest")
      assert account != nil
    end
  end

  describe "handle_event/1 with subscription metadata parsing" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "parses string 'true' and 'false' values in metadata", %{
      account: account,
      customer: customer
    } do
      # Build a subscription with string boolean metadata
      product =
        Stripe.build_product(
          id: "prod_test_team",
          name: "Team",
          metadata: %{
            "policy_conditions" => "true",
            "traffic_filters" => "false",
            "sites_count" => 100
          }
        )

      price = Stripe.build_price(product: product["id"])

      subscription =
        Stripe.build_subscription(customer: customer["id"], items: [[price: price, quantity: 5]])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.features.policy_conditions == true
      assert updated.features.traffic_filters == false
    end

    test "parses numeric string limits in metadata", %{account: account, customer: customer} do
      # Build a subscription with string number in metadata
      product =
        Stripe.build_product(
          id: "prod_test_team",
          name: "Team",
          metadata: %{
            "sites_count" => "50",
            "service_accounts_count" => "25"
          }
        )

      price = Stripe.build_price(product: product["id"])

      subscription =
        Stripe.build_subscription(customer: customer["id"], items: [[price: price, quantity: 5]])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.limits.sites_count == 50
      assert updated.limits.service_accounts_count == 25
    end
  end

  describe "handle_event/1 with subscription.resumed" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          },
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Stripe subscription paused"
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "re-enables account when subscription is resumed", %{
      account: account,
      customer: customer
    } do
      {product, _price, subscription} =
        Stripe.build_all(:team, account.metadata.stripe.customer_id, 10)

      # Make sure it's resumed (no pause_collection)
      subscription = Stripe.resume_subscription(subscription)

      event = Stripe.build_event("customer.subscription.resumed", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.disabled_at == nil
      assert updated_account.disabled_reason == nil
    end
  end

  describe "handle_event/1 with customer.updated - error paths" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "creates account when customer_not_provisioned", %{account: _account} do
      # Use a customer_id that doesn't have an account
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "New Customer Corp",
          email: "new@customer.com",
          metadata: %{
            "company_website" => "https://newcustomer.com",
            "account_owner_first_name" => "New",
            "account_owner_last_name" => "Customer"
          }
        )

      # Fetch customer returns no account_id, triggering customer_not_provisioned
      customer_without_account_id =
        Stripe.build_customer(id: customer_id, metadata: %{})

      event = Stripe.build_event("customer.updated", customer)

      Stripe.stub([
        {"GET", "/v1/customers/#{customer_id}", 200, customer_without_account_id},
        {"POST", "/v1/customers/#{customer_id}", 200, customer},
        {"POST", "/v1/subscriptions", 200, Stripe.subscription_object(customer_id, %{}, %{}, 1)}
      ])

      assert {:ok, _event} = EventHandler.handle_event(event)

      # Account should be created
      account = Portal.Repo.get_by(Portal.Account, slug: "newcustomer")
      assert account != nil
    end

    test "returns error when fetch_customer fails", %{account: _account} do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Error Corp",
          metadata: %{}
        )

      event = Stripe.build_event("customer.updated", customer)

      # Stripe fetch customer returns error
      Stripe.stub([{"GET", "/v1/customers/#{customer_id}", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = EventHandler.handle_event(event)
    end
  end

  describe "handle_event/1 with customer.deleted" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "disables account when customer is deleted", %{account: account, customer: customer} do
      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert :ok = EventHandler.handle_customer_deleted(customer)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.disabled_at != nil
      assert updated_account.disabled_reason == "Stripe customer deleted"
    end
  end

  describe "handle_event/1 with subscription error paths" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "returns error when fetch_customer fails during subscription update", %{
      account: account
    } do
      {_product, _price, subscription} =
        Stripe.build_all(:team, account.metadata.stripe.customer_id, 10)

      event = Stripe.build_event("customer.subscription.created", subscription)

      # Stripe fetch customer returns error
      Stripe.stub([
        {"GET", "/v1/customers/#{account.metadata.stripe.customer_id}", 500,
         %{"error" => "Server error"}}
      ])

      assert {:error, :retry_later} = EventHandler.handle_event(event)
    end
  end

  describe "handle_event/1 with customer.created - error paths" do
    test "returns slug_taken error when slug already exists" do
      # Create an existing account with the target slug
      _existing = account_fixture(%{slug: "slugconflict"})

      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Slug Conflict Corp",
          email: "admin@slugconflict.com",
          metadata: %{
            "company_website" => "https://slugconflict.com",
            "account_owner_first_name" => "Test",
            "account_owner_last_name" => "User"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      Stripe.stub([
        {"POST", "/v1/customers/#{customer_id}", 200, customer},
        {"POST", "/v1/subscriptions", 200, Stripe.subscription_object(customer_id, %{}, %{}, 1)}
      ])

      assert {:error, :slug_taken} = EventHandler.handle_event(event)
    end
  end

  describe "handle_event/1 with subscription metadata - boolean false" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "parses boolean false value in metadata", %{account: account, customer: customer} do
      product =
        Stripe.build_product(
          id: "prod_test_team",
          name: "Team",
          metadata: %{
            "policy_conditions" => false,
            "sites_count" => 100
          }
        )

      price = Stripe.build_price(product: product["id"])

      subscription =
        Stripe.build_subscription(customer: customer["id"], items: [[price: price, quantity: 5]])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.features.policy_conditions == false
    end

    test "ignores unrecognized metadata keys", %{account: account, customer: customer} do
      product =
        Stripe.build_product(
          id: "prod_test_team",
          name: "Team",
          metadata: %{
            "some_unknown_key" => "unknown_value",
            "another_random_field" => 123,
            "sites_count" => 50
          }
        )

      price = Stripe.build_price(product: product["id"])

      subscription =
        Stripe.build_subscription(customer: customer["id"], items: [[price: price, quantity: 5]])

      event = Stripe.build_event("customer.subscription.created", subscription)

      Stripe.stub(
        Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert {:ok, _event} = EventHandler.handle_event(event)

      # Should process without error, ignoring unrecognized keys
      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.limits.sites_count == 50
    end
  end

  describe "handle_event/1 chronological order - newer event" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      %{account: account, customer: customer}
    end

    test "processes newer event when older event was already processed", %{
      account: account,
      customer: customer
    } do
      # First, process an older event
      old_customer = Map.put(customer, "name", "Old Name")
      old_time = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_unix()
      old_event = Stripe.build_event("customer.updated", old_customer, old_time)

      Stripe.stub(Stripe.fetch_customer_endpoint(old_customer))

      assert {:ok, _event} = EventHandler.handle_event(old_event)

      updated = Portal.Repo.get!(Portal.Account, account.id)
      assert updated.legal_name == "Old Name"

      # Now process a newer event
      new_customer = Map.put(customer, "name", "New Name")
      new_time = DateTime.utc_now() |> DateTime.to_unix()
      new_event = Stripe.build_event("customer.updated", new_customer, new_time)

      Stripe.stub(Stripe.fetch_customer_endpoint(new_customer))

      assert {:ok, _event} = EventHandler.handle_event(new_event)

      # The newer event should be processed
      final = Portal.Repo.get!(Portal.Account, account.id)
      assert final.legal_name == "New Name"
    end
  end

  describe "Database.slug_exists?/1" do
    test "returns true when slug exists" do
      _account = account_fixture(%{slug: "existing_slug"})

      assert EventHandler.Database.slug_exists?("existing_slug") == true
    end

    test "returns false when slug does not exist" do
      assert EventHandler.Database.slug_exists?("nonexistent_slug") == false
    end
  end
end
