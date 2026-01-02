defmodule Portal.BillingTest do
  use Portal.DataCase, async: true

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
end
