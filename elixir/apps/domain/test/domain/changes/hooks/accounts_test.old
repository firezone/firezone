defmodule Domain.Changes.Hooks.AccountsTest do
  use Domain.DataCase, async: true
  alias Domain.{Accounts, Changes.Change, PubSub}
  import Domain.Changes.Hooks.Accounts

  describe "insert/1" do
    test "returns :ok for empty data" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "sends delete when account is disabled" do
      account_id = "00000000-0000-0000-0000-000000000001"

      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => account_id,
        "disabled_at" => nil
      }

      data = %{
        "id" => account_id,
        "disabled_at" => "2023-10-01T00:00:00Z"
      }

      assert :ok == on_update(0, old_data, data)
      assert_receive %Change{op: :delete, old_struct: %Domain.Account{} = account, lsn: 0}

      assert account.id == account_id
    end

    test "deletes associated policy authorizations when account is disabled" do
      account = Fixtures.Accounts.create_account()

      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(account: account)

      old_data = %{
        "id" => account.id,
        "disabled_at" => nil
      }

      data = %{
        "id" => account.id,
        "disabled_at" => "2023-10-01T00:00:00Z"
      }

      assert :ok == on_update(0, old_data, data)
      assert Repo.get_by(Domain.PolicyAuthorization, id: policy_authorization.id) == nil
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted account" do
      account_id = "00000000-0000-0000-0000-000000000003"
      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{"id" => account_id}

      assert :ok == on_delete(0, old_data)
      assert_receive %Change{op: :delete, old_struct: %Domain.Account{} = account, lsn: 0}
      assert account.id == account_id
    end
  end
end
