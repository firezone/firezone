defmodule Portal.LogSinks.DeliverySchemaTest do
  @moduledoc """
  Locks the wire type of every field the delivery engine renders.

  Destinations remember field types forever (Elasticsearch mappings are
  immutable), so changing an existing field's JSON type breaks every customer
  index that has already ingested it. If this test fails because you changed
  a type: don't. Add a NEW field with the new type instead, and deprecate the
  old one. Adding fields is safe; renaming or retyping existing ones is not.
  """
  use Portal.DataCase, async: true

  import Portal.APIRequestLogFixtures
  import Portal.AccountFixtures
  import Portal.ChangeLogFixtures
  import Portal.FlowLogFixtures
  import Portal.SessionLogFixtures

  alias Portal.LogSinks.Delivery

  @expected %{
    change: %{
      "type" => "string",
      "log_id" => "string",
      "timestamp" => "string",
      "object" => "string",
      "operation" => "string",
      "before" => "object",
      "after" => "object",
      "subject" => "object"
    },
    session: %{
      "type" => "string",
      "log_id" => "string",
      "timestamp" => "string",
      "context" => "string",
      "subject" => "object"
    },
    api_request: %{
      "type" => "string",
      "log_id" => "string",
      "timestamp" => "string",
      "actor_id" => "string",
      "api_token_id" => "string",
      "method" => "string",
      "path" => "string",
      "content_length" => "integer",
      "request_id" => "string",
      "user_agent" => "string",
      "ip" => "string",
      "ip_region" => "string",
      "ip_city" => "string"
    },
    flow: %{
      "type" => "string",
      "log_id" => "string",
      "phase" => "string",
      "flow_start" => "string",
      "flow_end" => "string",
      "last_packet" => "string",
      "device_id" => "string",
      "role" => "string",
      "policy_authorization_id" => "string",
      "policy_id" => "string",
      "resource_id" => "string",
      "resource_name" => "string",
      "resource_address" => "string",
      "actor_id" => "string",
      "actor_email" => "string",
      "actor_name" => "string",
      "client_version" => "string",
      "device_os_name" => "string",
      "device_os_version" => "string",
      "protocol" => "string",
      "inner_src_ip" => "string",
      "inner_src_port" => "integer",
      "inner_dst_ip" => "string",
      "inner_dst_port" => "integer",
      "outer_src_ip" => "string",
      "outer_src_port" => "integer",
      "outer_dst_ip" => "string",
      "outer_dst_port" => "integer",
      "domain" => "string",
      "rx_packets" => "integer",
      "tx_packets" => "integer",
      "rx_bytes" => "integer",
      "tx_bytes" => "integer"
    }
  }

  test "rendered field wire types never change" do
    account = account_fixture()

    rows = %{
      change:
        change_log_fixture(
          account: account,
          object: "resources",
          operation: :update,
          before: %{"name" => "old"},
          after: %{"name" => "new"},
          subject: %{"actor_id" => Ecto.UUID.generate()}
        ),
      session: session_log_fixture(account: account),
      api_request:
        api_request_log_fixture(
          account: account,
          content_length: 128,
          user_agent: "test-agent",
          ip_region: "CA",
          ip_city: "San Francisco"
        ),
      flow:
        flow_log_fixture(
          account: account,
          domain: "example.com",
          client_version: "1.0.0",
          device_os_name: "macOS",
          device_os_version: "15.0"
        )
    }

    for {stream, row} <- rows do
      {_time, event} = Delivery.render_event(stream, row)

      types =
        event
        |> JSON.encode!()
        |> JSON.decode!()
        |> Map.new(fn {field, value} -> {field, json_type(value)} end)

      assert types == @expected[stream],
             "wire types changed for the #{stream} stream; see the moduledoc before touching @expected"
    end
  end

  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_integer(value), do: "integer"
  defp json_type(value) when is_float(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(value) when is_map(value), do: "object"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(nil), do: "null"
end
