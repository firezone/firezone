defmodule Portal.BillingTest do
  use Portal.DataCase, async: true

  import Portal.Billing
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()

    %{account: account}
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
