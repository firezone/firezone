defmodule Domain.Events.EventTest do
  use Domain.DataCase, async: true
  alias Domain.Events.Decoder
  import Domain.Events.Event

  setup do
    account = Fixtures.Accounts.create_account()

    config = Application.fetch_env!(:domain, Domain.Events.ReplicationConnection)
    table_subscriptions = config[:table_subscriptions]

    %{account: account, table_subscriptions: table_subscriptions}
  end

  # TODO: WAL
  # Refactor this to test ingest of all table subscriptions as structs with stringified
  # keys in order to assert on the shape of the data.
  describe "ingest/2" do
    test "does not log an error when processing operations for a deleted account" do
      account_id = Ecto.UUID.generate()

      relations = %{
        1 => %{
          id: account_id,
          name: "accounts",
          columns: [
            %{name: "id", type: "binary_id"},
            %{name: "name", type: "string"}
          ]
        }
      }

      message = %Decoder.Messages.Insert{tuple_data: {account_id, "test"}, relation_id: 1}

      assert :ok = ingest(message, relations)

      assert [] = Repo.all(Domain.ChangeLogs.ChangeLog)
    end

    test "adds :insert operations to the change_logs table", %{account: account} do
      relations = %{
        1 => %{
          id: account.id,
          name: "accounts",
          columns: [
            %{name: "id", type: "binary_id"},
            %{name: "name", type: "string"}
          ]
        }
      }

      message = %Decoder.Messages.Insert{tuple_data: {account.id, "test"}, relation_id: 1}

      assert :ok = ingest(message, relations)

      assert [change_log] = Repo.all(Domain.ChangeLogs.ChangeLog)
      assert change_log.op == :insert
      assert change_log.table == "accounts"
      assert change_log.data == %{"id" => account.id, "name" => "test"}
      assert change_log.old_data == nil
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end

    test "adds :update operations to the change_logs table", %{account: account} do
      relations = %{
        1 => %{
          id: account.id,
          name: "accounts",
          columns: [
            %{name: "id", type: "binary_id"},
            %{name: "name", type: "string"},
            %{name: "config", type: "jsonb"}
          ]
        }
      }

      old_data = {account.id, "old_name", []}
      new_data = {account.id, "new_name", []}

      message = %Decoder.Messages.Update{
        old_tuple_data: old_data,
        tuple_data: new_data,
        relation_id: 1
      }

      assert :ok = ingest(message, relations)

      assert [change_log] = Repo.all(Domain.ChangeLogs.ChangeLog)
      assert change_log.op == :update
      assert change_log.table == "accounts"
      assert change_log.data == %{"id" => account.id, "name" => "new_name", "config" => []}
      assert change_log.old_data == %{"id" => account.id, "name" => "old_name", "config" => []}
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end

    test "adds :delete operations to the change_logs table", %{account: account} do
      relations = %{
        1 => %{
          id: account.id,
          name: "accounts",
          columns: [
            %{name: "id", type: "binary_id"},
            %{name: "name", type: "string"}
          ]
        }
      }

      old_data = {account.id, "test"}

      message = %Decoder.Messages.Delete{old_tuple_data: old_data, relation_id: 1}

      assert :ok = ingest(message, relations)

      assert [change_log] = Repo.all(Domain.ChangeLogs.ChangeLog)
      assert change_log.op == :delete
      assert change_log.table == "accounts"
      assert change_log.data == nil
      assert change_log.old_data == %{"id" => account.id, "name" => "test"}
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end
  end
end
