defmodule Portal.BillingTest do
  use Portal.DataCase, async: true

  import ExUnit.CaptureLog
  import Portal.Billing
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.Mocks.Stripe

  setup do
    account = account_fixture()

    %{account: account}
  end

  describe "enabled?/0" do
    test "returns true when billing is enabled" do
      assert enabled?() == true
    end

    test "returns false when billing is disabled" do
      Portal.Config.put_env_override(Portal.Billing, enabled: false)
      assert enabled?() == false
    end
  end

  describe "account_provisioned?/1" do
    test "returns true when account is provisioned", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_" <> Stripe.random_id()}}
        })

      assert account_provisioned?(account) == true
    end

    test "returns false when account is not provisioned", %{account: account} do
      account = update_account(account, %{metadata: %{stripe: %{}}})
      assert account_provisioned?(account) == false
    end
  end

  describe "users_limit_exceeded?/2" do
    test "returns false when users limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{users_count: 10}})
      assert users_limit_exceeded?(account, 10) == false
    end

    test "returns true when users limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{users_count: 10}})
      assert users_limit_exceeded?(account, 11) == true
    end

    test "returns false when users limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{users_count: nil}})
      assert users_limit_exceeded?(account, 1000) == false
    end
  end

  describe "seats_limit_exceeded?/2" do
    test "returns false when seats limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{monthly_active_users_count: 10}})
      assert seats_limit_exceeded?(account, 10) == false
    end

    test "returns true when seats limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{monthly_active_users_count: 10}})
      assert seats_limit_exceeded?(account, 11) == true
    end

    test "returns false when seats limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{monthly_active_users_count: nil}})
      assert seats_limit_exceeded?(account, 1000) == false
    end
  end

  describe "can_create_users?/1" do
    test "returns true when seats limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{monthly_active_users_count: 3}})

      actor1 = actor_fixture(type: :account_admin_user, account: account)
      client_fixture(account: account, actor: actor1)

      actor2 = actor_fixture(type: :account_user, account: account)
      client_fixture(account: account, actor: actor2)

      assert can_create_users?(account) == true
    end

    test "returns false when seats limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{monthly_active_users_count: 1}})

      actor1 = actor_fixture(type: :account_admin_user, account: account)
      client_fixture(account: account, actor: actor1)

      actor2 = actor_fixture(type: :account_user, account: account)
      client_fixture(account: account, actor: actor2)

      assert can_create_users?(account) == false
    end

    test "returns false when users limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{users_count: 1}})

      actor_fixture(type: :account_admin_user, account: account)
      actor_fixture(type: :account_user, account: account)

      assert can_create_users?(account) == false
    end

    test "returns false when account is disabled" do
      account = disabled_account_fixture()
      assert can_create_users?(account) == false
    end

    test "returns true when limits are not set", %{account: account} do
      account =
        update_account(account, %{
          limits: %{users_count: nil, monthly_active_users_count: nil}
        })

      assert can_create_users?(account) == true
    end
  end

  describe "service_accounts_limit_exceeded?/2" do
    test "returns false when service accounts limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{service_accounts_count: 10}})
      assert service_accounts_limit_exceeded?(account, 10) == false
    end

    test "returns true when service accounts limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{service_accounts_count: 10}})
      assert service_accounts_limit_exceeded?(account, 11) == true
    end

    test "returns false when service accounts limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{service_accounts_count: nil}})
      assert service_accounts_limit_exceeded?(account, 1000) == false
    end
  end

  describe "can_create_service_accounts?/1" do
    test "returns true when service accounts limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{service_accounts_count: 3}})

      actor_fixture(type: :service_account, account: account)
      actor_fixture(type: :service_account, account: account)

      assert can_create_service_accounts?(account) == true
    end

    test "returns false when service accounts limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{service_accounts_count: 1}})

      actor_fixture(type: :service_account, account: account)
      actor_fixture(type: :service_account, account: account)

      assert can_create_service_accounts?(account) == false
    end

    test "returns false when account is disabled" do
      account = disabled_account_fixture()
      assert can_create_service_accounts?(account) == false
    end

    test "returns true when service accounts limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{service_accounts_count: nil}})
      assert can_create_service_accounts?(account) == true
    end
  end

  describe "sites_limit_exceeded?/2" do
    test "returns false when sites limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{sites_count: 10}})
      assert sites_limit_exceeded?(account, 10) == false
    end

    test "returns true when sites limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{sites_count: 10}})
      assert sites_limit_exceeded?(account, 11) == true
    end

    test "returns false when sites limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{sites_count: nil}})
      assert sites_limit_exceeded?(account, 1000) == false
    end
  end

  describe "can_create_sites?/1" do
    test "returns true when sites limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{sites_count: 3}})

      site_fixture(account: account)
      site_fixture(account: account)

      assert can_create_sites?(account) == true
    end

    test "returns false when sites limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{sites_count: 1}})

      site_fixture(account: account)

      assert can_create_sites?(account) == false
    end

    test "returns false when account is disabled" do
      account = disabled_account_fixture()
      assert can_create_sites?(account) == false
    end

    test "returns true when sites limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{sites_count: nil}})
      assert can_create_sites?(account) == true
    end
  end

  describe "admins_limit_exceeded?/2" do
    test "returns false when admins limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{account_admin_users_count: 10}})
      assert admins_limit_exceeded?(account, 10) == false
    end

    test "returns true when admins limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{account_admin_users_count: 10}})
      assert admins_limit_exceeded?(account, 11) == true
    end

    test "returns false when admins limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{account_admin_users_count: nil}})
      assert admins_limit_exceeded?(account, 1000) == false
    end
  end

  describe "can_create_admin_users?/1" do
    test "returns true when admins limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{account_admin_users_count: 5}})

      actor_fixture(type: :account_admin_user, account: account)
      actor_fixture(type: :account_admin_user, account: account)

      assert can_create_admin_users?(account) == true
    end

    test "returns false when admins limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{account_admin_users_count: 1}})

      actor_fixture(type: :account_admin_user, account: account)

      assert can_create_admin_users?(account) == false
    end

    test "returns false when account is disabled" do
      account = disabled_account_fixture()
      assert can_create_admin_users?(account) == false
    end

    test "returns true when admins limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{account_admin_users_count: nil}})
      assert can_create_admin_users?(account) == true
    end
  end

  describe "api_clients_limit_exceeded?/2" do
    test "returns false when api_clients_count limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: 10}})

      assert api_clients_limit_exceeded?(account, 5) == false
    end

    test "returns false when api_clients_count equals limit", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: 10}})

      assert api_clients_limit_exceeded?(account, 10) == false
    end

    test "returns true when api_clients_count limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: 10}})

      assert api_clients_limit_exceeded?(account, 11) == true
    end

    test "returns false when api_clients_count limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: nil}})

      assert api_clients_limit_exceeded?(account, 1000) == false
    end
  end

  describe "can_create_api_clients?/1" do
    test "returns true when api_clients limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: 5}})

      api_client_fixture(account: account)
      api_client_fixture(account: account)

      assert can_create_api_clients?(account) == true
    end

    test "returns false when api_clients limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: 1}})

      api_client_fixture(account: account)

      assert can_create_api_clients?(account) == false
    end

    test "returns false when account is disabled" do
      account = disabled_account_fixture()

      assert can_create_api_clients?(account) == false
    end

    test "returns true when api_clients limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: nil}})

      assert can_create_api_clients?(account) == true
    end

    test "disabled API clients are not counted against limit", %{account: account} do
      account = update_account(account, %{limits: %{api_clients_count: 1}})

      api_client = api_client_fixture(account: account)
      disabled_actor_fixture(account: account, type: :api_client)

      # Only the enabled one counts
      refute can_create_api_clients?(account)

      # Disable the enabled one
      api_client
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      # Now we can create more
      assert can_create_api_clients?(account)
    end
  end

  describe "api_tokens_limit_exceeded?/2" do
    test "returns false when api_tokens_per_client_count limit is not exceeded", %{
      account: account
    } do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: 10}})

      assert api_tokens_limit_exceeded?(account, 5) == false
    end

    test "returns false when api_tokens_per_client_count equals limit", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: 10}})

      assert api_tokens_limit_exceeded?(account, 10) == false
    end

    test "returns true when api_tokens_per_client_count limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: 10}})

      assert api_tokens_limit_exceeded?(account, 11) == true
    end

    test "returns false when api_tokens_per_client_count limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: nil}})

      assert api_tokens_limit_exceeded?(account, 1000) == false
    end
  end

  describe "can_create_api_tokens?/2" do
    test "returns true when api_tokens limit is not exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: 5}})
      api_client = api_client_fixture(account: account)

      api_token_fixture(account: account, actor: api_client)
      api_token_fixture(account: account, actor: api_client)

      assert can_create_api_tokens?(account, api_client) == true
    end

    test "returns false when api_tokens limit is exceeded", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: 1}})
      api_client = api_client_fixture(account: account)

      api_token_fixture(account: account, actor: api_client)

      assert can_create_api_tokens?(account, api_client) == false
    end

    test "returns false when account is disabled" do
      account = disabled_account_fixture()
      api_client = api_client_fixture(account: account)

      assert can_create_api_tokens?(account, api_client) == false
    end

    test "returns true when api_tokens limit is not set", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: nil}})
      api_client = api_client_fixture(account: account)

      assert can_create_api_tokens?(account, api_client) == true
    end

    test "tokens are counted per API client, not globally", %{account: account} do
      account = update_account(account, %{limits: %{api_tokens_per_client_count: 2}})

      api_client1 = api_client_fixture(account: account)
      api_client2 = api_client_fixture(account: account)

      # Create 2 tokens for client1 (at limit)
      api_token_fixture(account: account, actor: api_client1)
      api_token_fixture(account: account, actor: api_client1)

      # Client1 is at limit
      assert can_create_api_tokens?(account, api_client1) == false

      # Client2 can still create tokens
      assert can_create_api_tokens?(account, api_client2) == true
    end
  end

  describe "client_sign_in_restricted?/1" do
    test "returns false when no limits are exceeded", %{account: account} do
      refute client_sign_in_restricted?(account)
    end

    test "returns true when users_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{users_limit_exceeded: true})
      assert client_sign_in_restricted?(account)
    end

    test "returns false when only seats_limit_exceeded is true", %{account: account} do
      # seats_limit_exceeded no longer blocks sign-in, it only logs
      account = update_account(account, %{seats_limit_exceeded: true})
      refute client_sign_in_restricted?(account)
    end

    test "returns true when users_limit_exceeded is true even with seats_limit_exceeded", %{
      account: account
    } do
      account = update_account(account, %{users_limit_exceeded: true, seats_limit_exceeded: true})
      assert client_sign_in_restricted?(account)
    end

    test "returns false when only sites_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{sites_limit_exceeded: true})
      refute client_sign_in_restricted?(account)
    end

    test "returns false when only service_accounts_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{service_accounts_limit_exceeded: true})
      refute client_sign_in_restricted?(account)
    end

    test "returns false when only admins_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{admins_limit_exceeded: true})
      refute client_sign_in_restricted?(account)
    end
  end

  describe "log_seats_limit_exceeded/2" do
    test "logs error when seats_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{seats_limit_exceeded: true})
      actor = actor_fixture(account: account)

      log =
        capture_log(fn ->
          assert log_seats_limit_exceeded(account, actor.id) == :ok
        end)

      assert log =~ "Account seats limit exceeded"
      assert log =~ "account_id=#{account.id}"
      assert log =~ "account_slug=#{account.slug}"
      assert log =~ "actor_id=#{actor.id}"
    end

    test "does not log when seats_limit_exceeded is false", %{account: account} do
      actor = actor_fixture(account: account)

      log =
        capture_log(fn ->
          assert log_seats_limit_exceeded(account, actor.id) == :ok
        end)

      refute log =~ "Account seats limit exceeded"
    end
  end

  describe "client_connect_restricted?/1" do
    test "returns false when no limits are exceeded", %{account: account} do
      refute client_connect_restricted?(account)
    end

    test "returns true when users_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{users_limit_exceeded: true})
      assert client_connect_restricted?(account)
    end

    test "returns false when only seats_limit_exceeded is true", %{account: account} do
      # seats_limit_exceeded no longer blocks connections, it only logs
      account = update_account(account, %{seats_limit_exceeded: true})
      refute client_connect_restricted?(account)
    end

    test "returns true when service_accounts_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{service_accounts_limit_exceeded: true})
      assert client_connect_restricted?(account)
    end

    test "returns false when only sites_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{sites_limit_exceeded: true})
      refute client_connect_restricted?(account)
    end

    test "returns false when only admins_limit_exceeded is true", %{account: account} do
      account = update_account(account, %{admins_limit_exceeded: true})
      refute client_connect_restricted?(account)
    end
  end

  describe "evaluate_account_limits/1" do
    test "returns account unchanged when not provisioned", %{account: account} do
      # Account without customer_id is not provisioned
      account = update_account(account, %{metadata: %{stripe: %{}}})
      assert {:ok, ^account} = Portal.Billing.evaluate_account_limits(account)
    end
  end

  describe "create_customer/1" do
    test "returns error when Stripe API returns 400 status", %{account: account} do
      Stripe.stub([{"POST", "/v1/customers", 400, %{"error" => "Bad request"}}])

      assert {:error, :retry_later} = Portal.Billing.create_customer(account)
    end

    test "returns error when Stripe API returns 500 status", %{account: account} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = Portal.Billing.create_customer(account)
    end

    test "uses billing_email from metadata when present", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{billing_email: "billing@example.com"}}
        })

      Stripe.stub(Stripe.mock_create_customer_endpoint(account))

      assert {:ok, _updated} = Portal.Billing.create_customer(account)
    end

    test "sends nil email when no billing_email in metadata", %{account: account} do
      # Account without billing_email in metadata
      account = update_account(account, %{metadata: %{stripe: %{}}})

      Stripe.stub(Stripe.mock_create_customer_endpoint(account))

      assert {:ok, _updated} = Portal.Billing.create_customer(account)
    end

    test "handles account with nil stripe metadata", %{account: account} do
      # Create a raw account struct with nil stripe metadata to test the edge case
      # This tests the `_ -> %{}` branch in update_account_metadata_changeset
      raw_account = %Portal.Account{
        id: account.id,
        name: account.name,
        legal_name: account.legal_name,
        slug: account.slug,
        metadata: %Portal.Account.Metadata{stripe: nil}
      }

      Stripe.stub(Stripe.mock_create_customer_endpoint(account))

      # This should still work even with nil stripe metadata
      assert {:ok, _updated} = Portal.Billing.create_customer(raw_account)
    end
  end

  describe "update_stripe_customer/1" do
    test "returns error when Stripe API returns 400 status", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      Stripe.stub([{"POST", "/v1/customers/cus_test123", 400, %{"error" => "Bad request"}}])

      assert {:error, :retry_later} = Portal.Billing.update_stripe_customer(account)
    end

    test "returns error when Stripe API returns 500 status", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      Stripe.stub([{"POST", "/v1/customers/cus_test123", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = Portal.Billing.update_stripe_customer(account)
    end
  end

  describe "fetch_customer_account_id/1" do
    test "returns error when Stripe API returns 400 status" do
      Stripe.stub([{"GET", "/v1/customers/cus_test123", 400, %{"error" => "Bad request"}}])

      assert {:error, :retry_later} = Portal.Billing.fetch_customer_account_id("cus_test123")
    end

    test "returns error when Stripe API returns 500 status" do
      Stripe.stub([{"GET", "/v1/customers/cus_test123", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = Portal.Billing.fetch_customer_account_id("cus_test123")
    end

    test "returns error when customer has no account_id in metadata" do
      customer =
        Stripe.build_customer(
          id: "cus_test123",
          metadata: %{"other_key" => "other_value"}
        )

      Stripe.stub([{"GET", "/v1/customers/cus_test123", 200, customer}])

      assert {:error, :customer_not_provisioned} =
               Portal.Billing.fetch_customer_account_id("cus_test123")
    end
  end

  describe "list_all_subscriptions/0" do
    test "calls Stripe API to list subscriptions" do
      subscriptions = %{
        "object" => "list",
        "has_more" => false,
        "data" => [Stripe.subscription_object("cus_test123", %{}, %{}, 1)]
      }

      Stripe.stub([{"GET", ~r/\/v1\/subscriptions/, 200, subscriptions}])

      assert {:ok, result} = Portal.Billing.list_all_subscriptions()
      assert is_list(result)
    end
  end

  describe "create_subscription/1" do
    test "returns error when Stripe API returns 400 status", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      Stripe.stub([{"POST", "/v1/subscriptions", 400, %{"error" => "Bad request"}}])

      assert {:error, :retry_later} = Portal.Billing.create_subscription(account)
    end

    test "returns error when Stripe API returns 500 status", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      Stripe.stub([{"POST", "/v1/subscriptions", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = Portal.Billing.create_subscription(account)
    end
  end

  describe "fetch_product/1" do
    test "returns error when Stripe API returns 400 status" do
      Stripe.stub([{"GET", "/v1/products/prod_test123", 400, %{"error" => "Bad request"}}])

      assert {:error, :retry_later} = Portal.Billing.fetch_product("prod_test123")
    end

    test "returns error when Stripe API returns 500 status" do
      Stripe.stub([{"GET", "/v1/products/prod_test123", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = Portal.Billing.fetch_product("prod_test123")
    end
  end

  describe "provision_account/1" do
    test "only creates internet site when billing is disabled", %{account: account} do
      Portal.Config.put_env_override(Portal.Billing, enabled: false)

      # Account should not have internet site yet
      assert {:error, :not_found} =
               Portal.Billing.Database.fetch_internet_site(account)

      assert {:ok, ^account} = Portal.Billing.provision_account(account)

      # Internet site and resource should be created
      assert {:ok, _site} = Portal.Billing.Database.fetch_internet_site(account)
      assert {:ok, _resource} = Portal.Billing.Database.fetch_internet_resource(account)
    end

    test "only creates internet site when account is already provisioned", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_already_provisioned"}}
        })

      assert {:ok, ^account} = Portal.Billing.provision_account(account)

      # Internet site and resource should be created
      assert {:ok, _site} = Portal.Billing.Database.fetch_internet_site(account)
      assert {:ok, _resource} = Portal.Billing.Database.fetch_internet_resource(account)
    end

    test "creates internet site and resource when they don't exist", %{account: account} do
      # Stub successful Stripe calls for the full provisioning flow
      customer = Stripe.build_customer(id: "cus_new123", metadata: %{"account_id" => account.id})
      subscription = Stripe.subscription_object("cus_new123", %{}, %{}, 1)

      Stripe.stub([
        {"POST", "/v1/customers", 200, customer},
        {"POST", "/v1/subscriptions", 200, subscription}
      ])

      assert {:ok, _provisioned} = Portal.Billing.provision_account(account)

      # Internet site and resource should be created
      assert {:ok, _site} = Portal.Billing.Database.fetch_internet_site(account)
      assert {:ok, _resource} = Portal.Billing.Database.fetch_internet_resource(account)
    end

    test "returns error when provisioning fails", %{account: account} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{"error" => "Server error"}}])

      assert {:error, :retry_later} = Portal.Billing.provision_account(account)
    end
  end

  describe "on_account_name_or_slug_changed/1" do
    test "returns :ok when account is not provisioned", %{account: account} do
      account = update_account(account, %{metadata: %{stripe: %{}}})
      assert :ok = Portal.Billing.on_account_name_or_slug_changed(account)
    end

    test "returns :ok when billing is disabled", %{account: account} do
      Portal.Config.put_env_override(Portal.Billing, enabled: false)

      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      assert :ok = Portal.Billing.on_account_name_or_slug_changed(account)
    end

    test "updates Stripe customer when provisioned and enabled", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      Stripe.stub(Stripe.mock_update_customer_endpoint(account))

      assert :ok = Portal.Billing.on_account_name_or_slug_changed(account)
    end
  end

  describe "billing_portal_url/3" do
    test "returns error when subject is not admin", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      actor = actor_fixture(type: :account_user, account: account)
      subject = Portal.SubjectFixtures.subject_fixture(account: account, actor: actor)

      assert {:error, :unauthorized} =
               Portal.Billing.billing_portal_url(account, "https://example.com", subject)
    end

    test "returns error when subject is admin of different account", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      other_account = account_fixture()
      actor = actor_fixture(type: :account_admin_user, account: other_account)
      subject = Portal.SubjectFixtures.subject_fixture(account: other_account, actor: actor)

      assert {:error, :unauthorized} =
               Portal.Billing.billing_portal_url(account, "https://example.com", subject)
    end

    test "returns URL when subject is admin of same account", %{account: account} do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test123"}}
        })

      actor = actor_fixture(type: :account_admin_user, account: account)
      subject = Portal.SubjectFixtures.subject_fixture(account: account, actor: actor)

      Stripe.stub(Stripe.mock_create_billing_session_endpoint(account))

      assert {:ok, url} =
               Portal.Billing.billing_portal_url(account, "https://example.com", subject)

      assert url =~ "billing.stripe.com"
    end
  end
end
