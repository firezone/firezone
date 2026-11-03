defmodule Portal.OTLP.MetricsExporterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  require Record

  alias Portal.Azure.ManagedIdentity
  alias Portal.OTLP.MetricsExporter

  @moduletag capture_log: true

  Record.defrecordp(
    :metric,
    Record.extract(:metric, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :gauge,
    Record.extract(:gauge, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  @endpoint "https://metrics.example.com/v1/metrics"

  setup do
    Req.Test.verify_on_exit!()
    test_pid = self()

    Req.Test.stub(ManagedIdentity, fn conn ->
      send(test_pid, :token_fetched)

      Req.Test.json(conn, %{
        "access_token" => "token",
        "expires_on" => System.system_time(:second) + 3600
      })
    end)

    :ok
  end

  test "classifies export response status codes" do
    {:ok, state} = MetricsExporter.init(%{endpoint: @endpoint, auth: :azure_managed_identity})

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

      assert MetricsExporter.export(metrics(), :otel_resource.create(%{}), state) == result
    end
  end

  test "sends static headers and fetches no token without auth" do
    test_pid = self()
    auth = {:headers, [{"authorization", "Basic abc"}]}
    {:ok, state} = MetricsExporter.init(%{endpoint: @endpoint, auth: auth})

    Req.Test.expect(MetricsExporter, fn conn ->
      send(test_pid, {:authorization, get_req_header(conn, "authorization")})
      send_resp(conn, 200, "")
    end)

    assert MetricsExporter.export(metrics(), :otel_resource.create(%{}), state) == :ok
    assert_received {:authorization, ["Basic abc"]}
    refute_received :token_fetched
  end

  defp metrics do
    [
      metric(
        name: "test",
        scope: :opentelemetry.instrumentation_scope("portal", "1.0", :undefined),
        data: gauge(datapoints: [])
      )
    ]
  end
end
