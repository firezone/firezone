defmodule PortalAPI.OTLPTest do
  use ExUnit.Case, async: true

  import Portal.OTLPFixtures

  alias PortalAPI.OTLP

  describe "data_points/1" do
    test "decodes what the gateway exports" do
      assert {:ok, data_points} = OTLP.data_points(gateway_export())

      assert data_points == [
               %{
                 name: "flow_logs.report.errors",
                 value: 3,
                 attributes: %{"error.type" => "io::ErrorKind::PermissionDenied"},
                 time_unix_nano: 2_000_000_000
               }
             ]
    end

    test "accepts 64-bit values sent as strings" do
      export =
        update_in(gateway_export(), ["resourceMetrics"], fn [resource_metrics] ->
          [
            update_in(resource_metrics, ["scopeMetrics"], fn [scope_metrics] ->
              [
                update_in(scope_metrics, ["metrics"], fn [metric] ->
                  [put_in(metric, ["sum", "dataPoints", Access.at(0), "asInt"], "3")]
                end)
              ]
            end)
          ]
        end)

      assert {:ok, [%{value: 3}]} = OTLP.data_points(export)
    end

    test "errs when the body is not an export request" do
      assert OTLP.data_points(%{"resourceMetrics" => "nope"}) == :error
    end
  end
end
