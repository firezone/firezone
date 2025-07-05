defmodule Domain.ChangeLogsTest do
  use Domain.DataCase, async: true
  import Domain.ChangeLogs

  describe "bulk_insert/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
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

      assert {1, nil} = bulk_insert([attrs])

      # Try to insert with same LSN but different data
      dupe_lsn_attrs = Map.put(attrs, :data, %{"account_id" => account.id, "key" => "new_value"})
      assert {0, nil} = bulk_insert([dupe_lsn_attrs])
    end

    test "raises not null constraint when account_id is missing" do
      attrs = %{
        # account_id is missing
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"key" => "value"},
        vsn: 1
      }

      assert_raise Postgrex.Error,
                   ~r/null value in column "account_id".*violates not-null constraint/,
                   fn ->
                     bulk_insert([attrs])
                   end
    end

    test "raises not null constraint when table is missing", %{account: account} do
      attrs = %{
        account_id: account.id,
        lsn: 1,
        # table is missing
        op: :insert,
        old_data: nil,
        data: %{"key" => "value"},
        vsn: 1
      }

      assert_raise Postgrex.Error,
                   ~r/null value in column "table".*violates not-null constraint/,
                   fn ->
                     bulk_insert([attrs])
                   end
    end

    test "raises not null constraint when op is missing", %{account: account} do
      attrs = %{
        account_id: account.id,
        lsn: 1,
        table: "resources",
        # op is missing
        old_data: nil,
        data: %{"key" => "value"},
        vsn: 1
      }

      assert_raise Postgrex.Error,
                   ~r/null value in column "op".*violates not-null constraint/,
                   fn ->
                     bulk_insert([attrs])
                   end
    end

    test "enforces data constraints based on operation type", %{account: account} do
      # Invalid insert (has old_data)
      assert_raise Postgrex.Error, ~r/valid_data_for_operation/, fn ->
        bulk_insert([
          %{
            account_id: account.id,
            lsn: 1,
            table: "resources",
            op: :insert,
            # Should be null for insert
            old_data: %{"id" => "123"},
            data: %{"id" => "123"},
            vsn: 1
          }
        ])
      end

      # Invalid update (missing old_data)
      assert_raise Postgrex.Error, ~r/valid_data_for_operation/, fn ->
        bulk_insert([
          %{
            account_id: account.id,
            lsn: 2,
            table: "resources",
            op: :update,
            # Should not be null for update
            old_data: nil,
            data: %{"id" => "123"},
            vsn: 1
          }
        ])
      end

      # Invalid delete (has data)
      assert_raise Postgrex.Error, ~r/valid_data_for_operation/, fn ->
        bulk_insert([
          %{
            account_id: account.id,
            lsn: 3,
            table: "resources",
            op: :delete,
            old_data: %{"id" => "123"},
            # Should be null for delete
            data: %{"id" => "123"},
            vsn: 1
          }
        ])
      end
    end
  end
end
