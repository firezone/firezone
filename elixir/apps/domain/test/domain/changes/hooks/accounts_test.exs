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
      assert_receive %Change{op: :delete, old_struct: %Accounts.Account{} = account, lsn: 0}

      assert account.id == account_id
    end

    test "sends delete when soft-deleted" do
      account_id = "00000000-0000-0000-0000-000000000002"
      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => account_id,
        "deleted_at" => nil
      }

      data = %{
        "id" => account_id,
        "deleted_at" => "2023-10-01T00:00:00Z"
      }

      assert :ok == on_update(0, old_data, data)
      assert_receive %Change{op: :delete, old_struct: %Accounts.Account{} = account, lsn: 0}

      assert account.id == account_id
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted account" do
      account_id = "00000000-0000-0000-0000-000000000003"
      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => account_id,
        "deleted_at" => "2023-10-01T00:00:00Z"
      }

      assert :ok == on_delete(0, old_data)
      assert_receive %Change{op: :delete, old_struct: %Accounts.Account{} = account, lsn: 0}
      assert account.id == account_id
      assert account.deleted_at == ~U[2023-10-01 00:00:00.000000Z]
    end

    test "deletes associated flows when account is deleted" do
      account = Fixtures.Accounts.create_account()
      flow = Fixtures.Flows.create_flow(account: account)

      old_data = %{
        "id" => account.id,
        "deleted_at" => "2023-10-01T00:00:00Z"
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Domain.Flows.Flow, id: flow.id) == nil
    end
  end
end
