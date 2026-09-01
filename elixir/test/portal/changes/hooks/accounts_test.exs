defmodule Portal.Changes.Hooks.AccountsTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.TokenFixtures
  alias Portal.Changes.Change
  alias Portal.PubSub
  import Portal.Changes.Hooks.Accounts

  setup do
    Portal.Config.put_env_override(
      :portal,
      :account_changes_topic,
      "accounts:#{inspect(make_ref())}"
    )

    :ok
  end

  describe "insert/1" do
    test "returns :ok for empty data" do
      assert :ok == on_insert(0, %{})
    end

    test "broadcasts an enabled account to relays" do
      account_id = "00000000-0000-0000-0000-000000000000"
      :ok = PubSub.Changes.subscribe_to_accounts()

      assert :ok == on_insert(0, %{"id" => account_id, "is_disabled" => false})

      assert_receive %Change{op: :insert, struct: %Portal.Account{id: ^account_id}, lsn: 0}
    end
  end

  describe "update/2" do
    test "sends delete when account is disabled" do
      account_id = "00000000-0000-0000-0000-000000000001"

      :ok = PubSub.Changes.subscribe(account_id, :accounts)
      :ok = PubSub.Changes.subscribe_to_accounts()

      old_data = %{
        "id" => account_id,
        "is_disabled" => false
      }

      data = %{
        "id" => account_id,
        "is_disabled" => true
      }

      assert :ok == on_update(0, old_data, data)
      assert_receive %Change{op: :delete, old_struct: %Portal.Account{} = account, lsn: 0}

      assert account.id == account_id
      assert_receive %Change{op: :delete, old_struct: %Portal.Account{id: ^account_id}, lsn: 0}
    end

    test "broadcasts an enabled account to relays" do
      account_id = "00000000-0000-0000-0000-000000000002"
      :ok = PubSub.Changes.subscribe_to_accounts()

      assert :ok ==
               on_update(
                 0,
                 %{"id" => account_id, "is_disabled" => true},
                 %{"id" => account_id, "is_disabled" => false}
               )

      assert_receive %Change{op: :insert, struct: %Portal.Account{id: ^account_id}, lsn: 0}
    end

    test "deletes associated policy authorizations when account is disabled" do
      account = account_fixture()
      policy_authorization = policy_authorization_fixture(account: account)

      old_data = %{
        "id" => account.id,
        "is_disabled" => false
      }

      data = %{
        "id" => account.id,
        "is_disabled" => true
      }

      assert :ok == on_update(0, old_data, data)
      assert Repo.get_by(Portal.PolicyAuthorization, id: policy_authorization.id) == nil
    end

    test "deletes associated client tokens when account is disabled" do
      account = account_fixture()
      client_token = client_token_fixture(account: account)

      old_data = %{
        "id" => account.id,
        "is_disabled" => false
      }

      data = %{
        "id" => account.id,
        "is_disabled" => true
      }

      assert :ok == on_update(0, old_data, data)
      assert Repo.get_by(Portal.ClientToken, id: client_token.id) == nil
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted account" do
      account_id = "00000000-0000-0000-0000-000000000003"
      :ok = PubSub.Changes.subscribe(account_id, :accounts)
      :ok = PubSub.Changes.subscribe_to_accounts()

      old_data = %{"id" => account_id}

      assert :ok == on_delete(0, old_data)
      assert_receive %Change{op: :delete, old_struct: %Portal.Account{} = account, lsn: 0}
      assert account.id == account_id
      assert_receive %Change{op: :delete, old_struct: %Portal.Account{id: ^account_id}, lsn: 0}
    end
  end
end
