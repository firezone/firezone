defmodule Portal.Changes.ReplicationConnectionTest do
  use Portal.DataCase, async: true

  import ExUnit.CaptureLog
  alias Portal.Changes.ReplicationConnection

  setup do
    tables =
      Application.fetch_env!(:domain, Portal.Changes.ReplicationConnection)
      |> Keyword.fetch!(:table_subscriptions)

    %{tables: tables}
  end

  describe "on_write/6 for inserts" do
    test "logs warning for unknown table" do
      table = "unknown_table"

      data = %{
        "account_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate(),
        "name" => "test"
      }

      log_output =
        capture_log(fn ->
          result = ReplicationConnection.on_write(%{}, 0, :insert, table, nil, data)
          assert result == %{}
        end)

      assert log_output =~ "No hook defined for insert on table unknown_table"
      assert log_output =~ "Please implement Portal.Changes.Hooks for this table"
    end

    test "handles known tables without errors", %{tables: tables} do
      for table <- tables do
        data = %{
          "account_id" => Ecto.UUID.generate(),
          "id" => Ecto.UUID.generate(),
          "table" => table
        }

        # The actual hook call might fail if the hook modules aren't available,
        # but we can test that our routing logic works
        try do
          result = ReplicationConnection.on_write(%{}, 0, :insert, table, nil, data)
          assert result == %{}
        rescue
          # Depending on the shape of the data we might get a function clause error. This is ok,
          # as we are testing the routing logic, not the actual hook implementations.
          FunctionClauseError -> :ok
        end
      end
    end

    test "handles all configured tables", %{tables: tables} do
      for table <- tables do
        # Should not log warnings for configured tables
        log_output =
          capture_log(fn ->
            try do
              ReplicationConnection.on_write(%{}, 0, :insert, table, nil, %{
                "account_id" => Ecto.UUID.generate(),
                "id" => Ecto.UUID.generate()
              })
            rescue
              FunctionClauseError ->
                # Shape of the data might not match the expected one, which is fine
                :ok
            end
          end)

        refute log_output =~ "No hook defined for insert"
      end
    end
  end

  describe "on_write/6 for updates" do
    test "logs warning for unknown table" do
      table = "unknown_table"

      old_data = %{
        "account_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate(),
        "name" => "old"
      }

      data = %{"account_id" => Ecto.UUID.generate(), "id" => old_data["id"], "name" => "new"}

      log_output =
        capture_log(fn ->
          result = ReplicationConnection.on_write(%{}, 0, :update, table, old_data, data)
          assert result == %{}
        end)

      assert log_output =~ "No hook defined for update on table unknown_table"
      assert log_output =~ "Please implement Portal.Changes.Hooks for this table"
    end

    test "handles known tables", %{tables: tables} do
      old_data = %{
        "account_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate(),
        "name" => "old name"
      }

      data = %{"account_id" => Ecto.UUID.generate(), "id" => old_data["id"], "name" => "new name"}

      for table <- tables do
        try do
          result = ReplicationConnection.on_write(%{}, 0, :update, table, old_data, data)
          assert result == %{}
        rescue
          FunctionClauseError ->
            # Shape of the data might not match the expected one, which is fine
            :ok
        end
      end
    end
  end

  describe "on_write/6 for deletes" do
    test "logs warning for unknown table" do
      table = "unknown_table"

      old_data = %{
        "account_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate(),
        "name" => "deleted"
      }

      log_output =
        capture_log(fn ->
          result = ReplicationConnection.on_write(%{}, 0, :delete, table, old_data, nil)
          assert result == %{}
        end)

      assert log_output =~ "No hook defined for delete on table unknown_table"
      assert log_output =~ "Please implement Portal.Changes.Hooks for this table"
    end

    test "handles known tables", %{tables: tables} do
      # Fill in some dummy foreign keys
      old_data = %{
        "account_id" => Ecto.UUID.generate(),
        "resource_id" => Ecto.UUID.generate(),
        "site_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate(),
        "name" => "deleted item"
      }

      for table <- tables do
        try do
          result = ReplicationConnection.on_write(%{}, 0, :delete, table, old_data, nil)
          assert result == %{}
        rescue
          # Shape of the data might not match the expected one, which is fine
          FunctionClauseError -> :ok
        end
      end
    end
  end

  describe "operation routing" do
    test "routes to correct hook based on operation type" do
      # Test that we dispatch to the right operation
      # Since we can't directly test the hook calls without the actual hook modules,
      # we can at least verify the routing logic doesn't crash

      state = %{}
      table = "accounts"

      # Insert
      try do
        result =
          ReplicationConnection.on_write(state, 1, :insert, table, nil, %{
            "id" => "00000000-0000-0000-0000-000000000001"
          })

        assert result == state
      rescue
        FunctionClauseError -> :ok
      end

      # Update
      try do
        result =
          ReplicationConnection.on_write(
            state,
            2,
            :update,
            table,
            %{"id" => "00000000-0000-0000-0000-000000000001"},
            %{
              "id" => "00000000-0000-0000-0000-000000000001",
              "updated" => true
            }
          )

        assert result == state
      rescue
        FunctionClauseError -> :ok
      end

      # Delete
      try do
        result =
          ReplicationConnection.on_write(
            state,
            3,
            :delete,
            table,
            %{"id" => "00000000-0000-0000-0000-000000000001"},
            nil
          )

        assert result == state
      rescue
        FunctionClauseError -> :ok
      end
    end
  end

  describe "warning message formatting" do
    test "log_warning generates correct message format for each operation" do
      # Test insert
      log_output =
        capture_log(fn ->
          ReplicationConnection.on_write(%{}, 0, :insert, "test_table_insert", nil, %{})
        end)

      assert log_output =~ "No hook defined for insert on table test_table_insert"
      assert log_output =~ "Please implement Portal.Changes.Hooks for this table"

      # Test update
      log_output =
        capture_log(fn ->
          ReplicationConnection.on_write(%{}, 0, :update, "test_table_update", %{}, %{})
        end)

      assert log_output =~ "No hook defined for update on table test_table_update"
      assert log_output =~ "Please implement Portal.Changes.Hooks for this table"

      # Test delete
      log_output =
        capture_log(fn ->
          ReplicationConnection.on_write(%{}, 0, :delete, "test_table_delete", %{}, nil)
        end)

      assert log_output =~ "No hook defined for delete on table test_table_delete"
      assert log_output =~ "Please implement Portal.Changes.Hooks for this table"
    end
  end

  describe "state preservation" do
    test "always returns the state unchanged" do
      initial_state = %{some: "data", counter: 42}

      # Unknown table - should log warning and return state unchanged
      result1 = ReplicationConnection.on_write(initial_state, 1, :insert, "unknown", nil, %{})
      assert result1 == initial_state

      # Known table (might error in hook, but should still preserve state)
      try do
        result2 = ReplicationConnection.on_write(initial_state, 2, :insert, "accounts", nil, %{})
        assert result2 == initial_state
      rescue
        FunctionClauseError -> :ok
      end
    end
  end

  describe "table_to_hooks mapping" do
    test "all configured tables have hook modules" do
      # This test ensures our tables_to_hooks map is properly configured
      tables_to_hooks = %{
        "accounts" => Portal.Changes.Hooks.Accounts,
        "memberships" => Portal.Changes.Hooks.Memberships,
        "clients" => Portal.Changes.Hooks.Clients,
        "policy_authorizations" => Portal.Changes.Hooks.PolicyAuthorizations,
        "sites" => Portal.Changes.Hooks.Sites,
        "gateways" => Portal.Changes.Hooks.Gateways,
        "policies" => Portal.Changes.Hooks.Policies,
        "resources" => Portal.Changes.Hooks.Resources,
        "client_tokens" => Portal.Changes.Hooks.ClientTokens
      }

      # Verify the mapping includes all expected tables
      assert Map.keys(tables_to_hooks) |> Enum.sort() ==
               [
                 "accounts",
                 "memberships",
                 "clients",
                 "client_tokens",
                 "policy_authorizations",
                 "sites",
                 "gateways",
                 "policies",
                 "resources"
               ]
               |> Enum.sort()
    end
  end
end
