defmodule Portal.OTLPFixtures do
  @moduledoc """
  Test helpers for the OTLP/JSON payloads gateways export metrics in.
  """

  @doc """
  Verbatim output of the gateway's exporter, which pins our decoder to it.

  The gateway reports the flow-log error counter and nothing else, with the
  resource stripped because the token the report is authorized with already
  identifies the gateway.
  """
  def gateway_export do
    %{
      "resourceMetrics" => [
        %{
          "resource" => nil,
          "scopeMetrics" => [
            %{
              "scope" => %{
                "name" => "connlib",
                "version" => "",
                "attributes" => [],
                "droppedAttributesCount" => 0
              },
              "metrics" => [
                %{
                  "name" => "flow_logs.errors",
                  "description" =>
                    "Number of errors encountered while recording, spooling or uploading flow logs.",
                  "unit" => "{error}",
                  "metadata" => [],
                  "sum" => %{
                    "dataPoints" => [
                      %{
                        "attributes" => [
                          %{"key" => "error.type", "value" => %{"stringValue" => "spool_full"}}
                        ],
                        "startTimeUnixNano" => "1000000000",
                        "timeUnixNano" => "2000000000",
                        "exemplars" => [],
                        "flags" => 0,
                        "asInt" => 3
                      }
                    ],
                    "aggregationTemporality" => 1,
                    "isMonotonic" => true
                  }
                }
              ],
              "schemaUrl" => ""
            }
          ],
          "schemaUrl" => ""
        }
      ]
    }
  end
end
