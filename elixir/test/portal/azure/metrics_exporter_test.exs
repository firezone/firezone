defmodule Portal.Azure.MetricsExporterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  require Record

  alias Portal.Azure.{ManagedIdentity, MetricsExporter}

  @moduletag capture_log: true

  Record.defrecordp(
    :metric,
    Record.extract(:metric, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :gauge,
    Record.extract(:gauge, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  setup do
    Req.Test.verify_on_exit!()

    Req.Test.stub(ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "token",
        "expires_on" => System.system_time(:second) + 3600
      })
    end)

    :ok
  end

  test "classifies export response status codes" do
    metrics = [
      metric(
        name: "test",
        scope: :opentelemetry.instrumentation_scope("portal", "1.0", :undefined),
        data: gauge(datapoints: [])
      )
    ]

    resource = :otel_resource.create(%{})

    for {status, result} <- [
          {200, :ok},
          {201, :ok},
          {202, :ok},
          {302, :failed_not_retryable},
          {400, :failed_not_retryable},
          {401, :failed_not_retryable},
          {403, :failed_not_retryable},
          {408, :failed_retryable},
          {429, :failed_retryable},
          {500, :failed_retryable},
          {502, :failed_retryable},
          {503, :failed_retryable},
          {504, :failed_retryable}
        ] do
      Req.Test.expect(MetricsExporter, fn conn -> send_resp(conn, status, "") end)

      assert MetricsExporter.export(metrics, resource, "https://metrics.example.com/v1/metrics") ==
               result
    end
  end
end
