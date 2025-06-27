defmodule Domain.ChangeLogsTest do
  use Domain.DataCase, async: true
  import Domain.ChangeLogs

  describe "create/1" do
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

      assert {:ok, %Domain.ChangeLogs.ChangeLog{} = change_log} = create_change_log(attrs)

      assert change_log.account_id == account.id
      assert change_log.op == :insert
      assert change_log.old_data == nil
      assert change_log.data == %{"account_id" => account.id, "key" => "value"}
    end

    test "uses the 'id' field accounts table updates", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "accounts",
        op: :update,
        old_data: %{"id" => account.id, "name" => "Old Name"},
        data: %{"id" => account.id, "name" => "New Name"},
        vsn: 1
      }

      assert {:ok, %Domain.ChangeLogs.ChangeLog{} = change_log} = create_change_log(attrs)

      assert change_log.account_id == account.id
      assert change_log.op == :update
      assert change_log.old_data == %{"id" => account.id, "name" => "Old Name"}
      assert change_log.data == %{"id" => account.id, "name" => "New Name"}
    end

    test "requires vsn field", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"}
      }

      assert {:error, changeset} = create_change_log(attrs)
      assert changeset.valid? == false
      assert changeset.errors[:vsn] == {"can't be blank", [validation: :required]}
    end

    test "requires table field", %{account: account} do
      attrs = %{
        lsn: 1,
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"},
        vsn: 1
      }

      assert {:error, changeset} = create_change_log(attrs)
      assert changeset.valid? == false
      assert changeset.errors[:table] == {"can't be blank", [validation: :required]}
    end

    test "prevents inserting duplicate lsn", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"},
        vsn: 1
      }

      assert {:ok, _change_log} = create_change_log(attrs)

      dupe_lsn_attrs = Map.put(attrs, :data, %{"account_id" => account.id, "key" => "new_value"})

      assert {:error, changeset} = create_change_log(dupe_lsn_attrs)
      assert changeset.valid? == false

      assert changeset.errors[:lsn] ==
               {"has already been taken",
                [constraint: :unique, constraint_name: "change_logs_lsn_index"]}
    end

    test "requires op field to be one of :insert, :update, :delete", %{account: account} do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :invalid_op,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "value"},
        vsn: 1
      }

      assert {:error, changeset} = create_change_log(attrs)
      assert changeset.valid? == false
      assert {"is invalid", errors} = changeset.errors[:op]
      assert {:validation, :inclusion} in errors
    end

    test "requires correct combination of operation and data", %{account: account} do
      # Invalid combination: :insert with old_data present
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: %{"account_id" => account.id, "key" => "old_value"},
        data: %{"account_id" => account.id, "key" => "new_value"},
        vsn: 1
      }

      assert {:error, changeset} = create_change_log(attrs)
      assert changeset.valid? == false
      assert changeset.errors[:base] == {"Invalid combination of operation and data", []}

      # Valid combination: :insert with old_data nil and data present
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"account_id" => account.id, "key" => "new_value"},
        vsn: 1
      }

      assert {:ok, _change_log} = create_change_log(attrs)

      # Valid combination: :update with both old_data and data present
      attrs = %{
        lsn: 2,
        table: "resources",
        op: :update,
        old_data: %{"account_id" => account.id, "key" => "old_value"},
        data: %{"account_id" => account.id, "key" => "new_value"},
        vsn: 1
      }

      assert {:ok, _change_log} = create_change_log(attrs)

      # Valid combination: :delete with old_data present and data nil
      attrs = %{
        lsn: 3,
        table: "resources",
        op: :delete,
        old_data: %{"account_id" => account.id, "key" => "old_value"},
        data: nil,
        vsn: 1
      }

      assert {:ok, _change_log} = create_change_log(attrs)
    end

    test "requires account_id to be populated from old_data or data" do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"key" => "value"},
        vsn: 1
      }

      assert {:error, changeset} = create_change_log(attrs)
      assert changeset.valid? == false
      assert changeset.errors[:account_id] == {"can't be blank", [validation: :required]}
    end

    test "requires old_data[\"account_id\"] and data[\"account_id\"] to match", %{
      account: account
    } do
      attrs = %{
        lsn: 1,
        table: "resources",
        op: :update,
        old_data: %{"account_id" => account.id, "key" => "old_value"},
        data: %{"account_id" => "different_account_id", "key" => "new_value"},
        vsn: 1
      }

      assert {:error, changeset} = create_change_log(attrs)
      assert changeset.valid? == false
      assert changeset.errors[:base] == {"Account ID cannot be changed", []}
    end
  end
end
