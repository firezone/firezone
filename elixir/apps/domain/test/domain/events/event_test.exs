defmodule Domain.Events.EventTest do
  use ExUnit.Case, async: true
  import Domain.Events.Event
  alias Domain.Events.Decoder

  setup do
    config = Application.fetch_env!(:domain, Domain.Events.ReplicationConnection)
    table_subscriptions = config[:table_subscriptions]

    %{table_subscriptions: table_subscriptions}
  end

  describe "ingest/2" do
    test "returns :ok for insert on all configured table subscriptions", %{
      table_subscriptions: table_subscriptions
    } do
      for table <- table_subscriptions do
        relations = %{"1" => %{name: table, columns: []}}
        msg = %Decoder.Messages.Insert{tuple_data: {}, relation_id: "1"}

        assert :ok == ingest(msg, relations)
      end
    end

    test "returns :ok for update on all configured table subscriptions", %{
      table_subscriptions: table_subscriptions
    } do
      for table <- table_subscriptions do
        relations = %{"1" => %{name: table, columns: []}}
        msg = %Decoder.Messages.Update{old_tuple_data: {}, tuple_data: {}, relation_id: "1"}

        assert :ok == ingest(msg, relations)
      end
    end

    test "returns :ok for delete on all configured table subscriptions", %{
      table_subscriptions: table_subscriptions
    } do
      for table <- table_subscriptions do
        relations = %{"1" => %{name: table, columns: []}}
        msg = %Decoder.Messages.Delete{old_tuple_data: {}, relation_id: "1"}

        assert :ok == ingest(msg, relations)
      end
    end
  end
end
