defmodule PortalAPI.OTLPTest do
  use ExUnit.Case, async: true

  alias PortalAPI.OTLP

  describe "data_points/1" do
    test "decodes what the gateway exports" do
      assert {:ok, data_points} = OTLP.data_points(gateway_export())

      assert data_points == [
               %{
                 name: "flow_logs.errors",
                 value: 3,
                 attributes: %{"error.type" => "spool_full"},
                 time_unix_nano: 2_000_000_000
               }
             ]
    end

    test "accepts 64-bit values sent as numbers" do
      export =
        update_in(gateway_export(), ["resourceMetrics"], fn [resource_metrics] ->
          [
            update_in(resource_metrics, ["scopeMetrics"], fn [scope_metrics] ->
              [
                update_in(scope_metrics, ["metrics"], fn [metric] ->
                  [put_in(metric, ["sum", "dataPoints", Access.at(0), "asInt"], 3)]
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

  # Verbatim output of the gateway's exporter, which pins this decoder to it.
  defp gateway_export do
    %{
      "resourceMetrics" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "firezone-gateway"}}
            ]
          },
          "scopeMetrics" => [
            %{
              "scope" => %{"name" => "portal-metrics", "version" => "0.1.0"},
              "metrics" => [
                %{
                  "name" => "flow_logs.errors",
                  "description" => "Number of flow-log errors.",
                  "unit" => "{error}",
                  "sum" => %{
                    "dataPoints" => [
                      %{
                        "attributes" => [
                          %{"key" => "error.type", "value" => %{"stringValue" => "spool_full"}}
                        ],
                        "startTimeUnixNano" => "1000000000",
                        "timeUnixNano" => "2000000000",
                        "asInt" => "3"
                      }
                    ],
                    "aggregationTemporality" => 1,
                    "isMonotonic" => true
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
