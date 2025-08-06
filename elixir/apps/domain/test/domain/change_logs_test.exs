defmodule Domain.ChangeLogsTest do
  use Domain.DataCase, async: true
  import Domain.ChangeLogs
  alias Domain.ChangeLogs.ChangeLog

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

  describe "truncate/2" do
    setup do
      account1 = Fixtures.Accounts.create_account()
      account2 = Fixtures.Accounts.create_account()
      %{account1: account1, account2: account2}
    end

    test "deletes change logs before cutoff for specific account", %{
      account1: account1
    } do
      now = DateTime.utc_now()

      # Create some old records (before cutoff)
      old_attrs = [
        %{
          account_id: account1.id,
          lsn: 1,
          table: "resources",
          op: :insert,
          old_data: nil,
          data: %{"id" => "1"},
          vsn: 1,
          inserted_at: now |> DateTime.add(-10, :second)
        },
        %{
          account_id: account1.id,
          lsn: 2,
          table: "resources",
          op: :update,
          old_data: %{"id" => "1", "name" => "old"},
          data: %{"id" => "1", "name" => "new"},
          vsn: 1,
          inserted_at: now |> DateTime.add(-10, :second)
        }
      ]

      assert {2, nil} = bulk_insert(old_attrs)

      # Create some new records (after cutoff)
      new_attrs = %{
        account_id: account1.id,
        lsn: 3,
        table: "resources",
        op: :delete,
        old_data: %{"id" => "1"},
        data: nil,
        vsn: 1,
        inserted_at: now |> DateTime.add(10, :second)
      }

      assert {1, nil} = bulk_insert([new_attrs])

      # Truncate old records
      assert {2, nil} = truncate(account1, now)

      # Verify only the new record remains
      remaining = Repo.all(ChangeLog.Query.by_account_id(ChangeLog.Query.all(), account1.id))
      assert length(remaining) == 1
      assert hd(remaining).lsn == 3
    end

    test "does not delete records from other accounts", %{account1: account1, account2: account2} do
      now = DateTime.utc_now()

      # Create records for both accounts before cutoff
      account1_attrs = %{
        account_id: account1.id,
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"id" => "1"},
        vsn: 1,
        inserted_at: now |> DateTime.add(-10, :second)
      }

      account2_attrs = %{
        account_id: account2.id,
        lsn: 2,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"id" => "2"},
        vsn: 1,
        inserted_at: now |> DateTime.add(-10, :second)
      }

      assert {1, nil} = bulk_insert([account1_attrs])
      assert {1, nil} = bulk_insert([account2_attrs])

      # Truncate only account1's records
      assert {1, nil} = truncate(account1, DateTime.utc_now())

      # Verify account1's records are gone
      account1_remaining =
        Repo.all(ChangeLog.Query.by_account_id(ChangeLog.Query.all(), account1.id))

      assert length(account1_remaining) == 0

      # Verify account2's records remain
      account2_remaining =
        Repo.all(ChangeLog.Query.by_account_id(ChangeLog.Query.all(), account2.id))

      assert length(account2_remaining) == 1
      assert hd(account2_remaining).lsn == 2
    end

    test "does not delete records inserted after cutoff", %{account1: account1} do
      now = DateTime.utc_now()

      # Create record before cutoff
      old_attrs = %{
        account_id: account1.id,
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"id" => "1"},
        vsn: 1,
        inserted_at: now |> DateTime.add(-10, :second)
      }

      assert {1, nil} = bulk_insert([old_attrs])

      # Create record after cutoff
      new_attrs = %{
        account_id: account1.id,
        lsn: 2,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"id" => "2"},
        vsn: 1,
        inserted_at: now |> DateTime.add(10, :second)
      }

      assert {1, nil} = bulk_insert([new_attrs])

      # Truncate should only delete the old record
      assert {1, nil} = truncate(account1, now)

      # Verify only the new record remains
      remaining = Repo.all(ChangeLog.Query.by_account_id(ChangeLog.Query.all(), account1.id))
      assert length(remaining) == 1
      assert hd(remaining).lsn == 2
    end

    test "returns {0, nil} when no records match criteria", %{account1: account1} do
      now = DateTime.utc_now()

      # Create record right at cutoff
      attrs = %{
        account_id: account1.id,
        lsn: 1,
        table: "resources",
        op: :insert,
        old_data: nil,
        data: %{"id" => "1"},
        vsn: 1,
        inserted_at: now
      }

      assert {1, nil} = bulk_insert([attrs])

      # Truncate with cutoff before any records
      assert {0, nil} = truncate(account1, now)

      # Verify record still exists
      remaining = Repo.all(ChangeLog.Query.by_account_id(ChangeLog.Query.all(), account1.id))
      assert length(remaining) == 1
    end

    test "handles empty table gracefully", %{account1: account1} do
      cutoff = DateTime.utc_now()

      # No records exist
      assert {0, nil} = truncate(account1, cutoff)
    end

    test "deletes all records when cutoff is in the future", %{account1: account1} do
      # Create some records
      attrs = [
        %{
          account_id: account1.id,
          lsn: 1,
          table: "resources",
          op: :insert,
          old_data: nil,
          data: %{"id" => "1"},
          vsn: 1
        },
        %{
          account_id: account1.id,
          lsn: 2,
          table: "resources",
          op: :insert,
          old_data: nil,
          data: %{"id" => "2"},
          vsn: 1
        }
      ]

      assert {2, nil} = bulk_insert(attrs)

      # Set cutoff far in the future
      future_cutoff = DateTime.utc_now() |> DateTime.add(1, :hour)

      # All records should be deleted
      assert {2, nil} = truncate(account1, future_cutoff)

      # Verify no records remain
      remaining = Repo.all(ChangeLog.Query.by_account_id(ChangeLog.Query.all(), account1.id))
      assert length(remaining) == 0
    end
  end
end
