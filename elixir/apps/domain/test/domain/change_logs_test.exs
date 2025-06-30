defmodule Domain.ChangeLogsTest do
  use Domain.DataCase, async: true
  import Domain.ChangeLogs

  describe "bulk_insert/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{account: account}
    end

    test "inserts a change_log for an account", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"},
        vsn: 1
      }

      assert {1, [change_log]} = bulk_insert([attrs])
      assert change_log.lsn == 1
    end

    test "uses the 'id' field for accounts table updates", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "accounts",
        op: :update,
        old_data: %{"id" => account.id, "name" => "Old Name"},
        data: %{"id" => account.id, "name" => "New Name"},
        vsn: 1
      }

      assert {1, [change_log]} = bulk_insert([attrs])
      assert change_log.lsn == 1
    end

    test "requires vsn field", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"}
      }

      assert_raise(Postgrex.Error, ~r/23502/, fn ->
        bulk_insert([attrs])
      end)
    end

    test "requires table field", %{account: account} do
      attrs = %{
        account_id: Ecto.UUID.generate(),
        lsn: 1,
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"},
        vsn: 1
      }

      assert_raise(Postgrex.Error, ~r/23502/, fn ->
        bulk_insert([attrs])
      end)
    end

    test "skips duplicate lsn", %{account: account} do
      attrs = %{
        account_id: account.id,
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"},
        vsn: 1
      }

      assert {1, [_change_log]} = bulk_insert([attrs])

      dupe_lsn_attrs = Map.put(attrs, :data, %{"account_id" => account.id, "key" => "new_value"})

      assert {0, []} = bulk_insert([dupe_lsn_attrs])
    end

    test "filters out data with empty account_id" do
      attrs = [
        %{
          lsn: 1,
          table: "resources",
          op: :insert,
          old_data: nil,
          data: %{"key" => "value"},
          vsn: 1
        },
        %{
          lsn: 2,
          table: "resources",
          op: :insert,
          old_data: nil,
          data: %{"key" => "value", "account_id" => Ecto.UUID.generate()},
          vsn: 1
        }
      ]

      assert {1, [change_log]} = bulk_insert(attrs)
      assert change_log.lsn == 2
    end
  end
end
