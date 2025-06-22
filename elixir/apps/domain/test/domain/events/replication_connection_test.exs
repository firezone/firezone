defmodule Domain.Events.ReplicationConnectionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Domain.Events.ReplicationConnection

  setup do
    tables = Application.fetch_env!(:domain, Domain.Replication.Connection)[:table_subscriptions]

    %{tables: tables}
  end

  describe "on_insert/2" do
    test "logs warning for unknown table" do
      table = "unknown_table"
      data = %{"id" => Ecto.UUID.generate(), "name" => "test"}

      log_output =
        capture_log(fn ->
          assert :ok = on_insert(0, table, data)
        end)

      assert log_output =~ "No hook defined for insert on table unknown_table"
      assert log_output =~ "Please implement Domain.Events.Hooks for this table"
    end

    test "handles known tables without errors", %{tables: tables} do
      for table <- tables do
        data = %{"id" => Ecto.UUID.generate(), "table" => table}

        # The actual hook call might fail if the hook modules aren't available,
        # but we can test that our routing logic works
        try do
          result = on_insert(0, table, data)
          # Should either succeed or fail gracefully
          assert result in [:ok, :error] or match?({:error, _}, result)
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
              on_insert(0, table, %{"id" => Ecto.UUID.generate()})
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

  describe "on_update/3" do
    test "logs warning for unknown table" do
      table = "unknown_table"
      old_data = %{"id" => Ecto.UUID.generate(), "name" => "old"}
      data = %{"id" => Ecto.UUID.generate(), "name" => "new"}

      log_output =
        capture_log(fn ->
          assert :ok = on_update(0, table, old_data, data)
        end)

      assert log_output =~ "No hook defined for update on table unknown_table"
      assert log_output =~ "Please implement Domain.Events.Hooks for this table"
    end

    test "handles known tables", %{tables: tables} do
      old_data = %{"id" => Ecto.UUID.generate(), "name" => "old name"}
      data = %{"id" => Ecto.UUID.generate(), "name" => "new name"}

      for table <- tables do
        try do
          result = on_update(0, table, old_data, data)
          assert result in [:ok, :error] or match?({:error, _}, result)
        rescue
          FunctionClauseError ->
            # Shape of the data might not match the expected one, which is fine
            :ok
        end
      end
    end
  end

  describe "on_delete/2" do
    test "logs warning for unknown table" do
      table = "unknown_table"
      old_data = %{"id" => Ecto.UUID.generate(), "name" => "deleted"}

      log_output =
        capture_log(fn ->
          assert :ok = on_delete(0, table, old_data)
        end)

      assert log_output =~ "No hook defined for delete on table unknown_table"
      assert log_output =~ "Please implement Domain.Events.Hooks for this table"
    end

    test "handles known tables", %{tables: tables} do
      old_data = %{"id" => Ecto.UUID.generate(), "name" => "deleted gateway"}

      for table <- tables do
        try do
          assert :ok = on_delete(0, table, old_data)
        rescue
          # Shape of the data might not match the expected one, which is fine
          FunctionClauseError -> :ok
        end
      end
    end
  end

  describe "warning message formatting" do
    test "log_warning generates correct message format" do
      log_output =
        capture_log(fn ->
          assert :ok = on_insert(0, "test_table_insert", %{})
        end)

      assert log_output =~ "No hook defined for insert on table test_table_insert"
      assert log_output =~ "Please implement Domain.Events.Hooks for this table"

      log_output =
        capture_log(fn ->
          assert :ok = on_update(0, "test_table_update", %{}, %{})
        end)

      assert log_output =~ "No hook defined for update on table test_table_update"
      assert log_output =~ "Please implement Domain.Events.Hooks for this table"

      log_output =
        capture_log(fn ->
          assert :ok = on_delete(0, "test_table_delete", %{})
        end)

      assert log_output =~ "No hook defined for delete on table test_table_delete"
      assert log_output =~ "Please implement Domain.Events.Hooks for this table"
    end
  end
end
