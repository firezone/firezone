defmodule Domain.Events.EventTest do
  use ExUnit.Case, async: true
  # import Domain.Events.Event
  # alias Domain.Events.Decoder

  setup do
    config = Application.fetch_env!(:domain, Domain.Events.ReplicationConnection)
    table_subscriptions = config[:table_subscriptions]

    %{table_subscriptions: table_subscriptions}
  end

  # TODO: WAL
  # Refactor this to test ingest of all table subscriptions as structs with stringified
  # keys in order to assert on the shape of the data.
  # describe "ingest/2" do
  #   test "returns :ok for insert on all configured table subscriptions", %{
  #     table_subscriptions: table_subscriptions
  #   } do
  #     for table <- table_subscriptions do
  #       relations = %{"1" => %{name: table, columns: []}}
  #       msg = %Decoder.Messages.Insert{tuple_data: {}, relation_id: "1"}
  #
  #       assert :ok == ingest(msg, relations)
  #     end
  #   end
  # end
end
