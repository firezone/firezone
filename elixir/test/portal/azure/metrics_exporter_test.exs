defmodule Portal.Azure.MetricsExporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  require Record

  alias Portal.Azure.{ManagedIdentity, MetricsExporter}

  Record.defrecordp(
    :metric,
    Record.extract(:metric, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :histogram,
    Record.extract(:histogram, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :histogram_datapoint,
    Record.extract(:histogram_datapoint,
      from_lib: "opentelemetry_experimental/include/otel_metrics.hrl"
    )
  )

  @endpoint "https://metrics.example.com/datacollectionRules/dcr-id/streams/Custom-Metrics-Otel/otlp/v1/metrics?test=1"

  setup do
    Req.Test.verify_on_exit!()
  end

  test "initializes without fetching credentials and requires HTTPS" do
    assert :otel_exporter_metrics.init({MetricsExporter, %{endpoint: @endpoint}}) ==
             {MetricsExporter, @endpoint}

    assert_raise ArgumentError, fn ->
      MetricsExporter.init(%{endpoint: "http://metrics.example.com/v1/metrics"})
    end
  end

  test "exports full histogram buckets to the exact URL with refreshed cached credentials" do
    name = :"metrics_token_cache_#{System.unique_integer([:positive])}"
    server = start_supervised!({Portal.TokenCache, name: name})
    Portal.Config.put_env_override(:portal, ManagedIdentity, token_cache: server)
    Req.Test.stub(ManagedIdentity, fn conn -> Req.Test.json(conn, %{}) end)
    Req.Test.allow(ManagedIdentity, self(), server)

    for token <- ["initial-token", "refreshed-token"] do
      Req.Test.expect(ManagedIdentity, fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["resource"] == "https://monitor.azure.com/"
        assert params["client_id"] == "test-azure-client-id"

        Req.Test.json(conn, %{
          "access_token" => token,
          "expires_on" => System.system_time(:second) + 60
        })
      end)

      Req.Test.expect(MetricsExporter, fn conn ->
        assert conn.method == "POST"
        assert conn.host == "metrics.example.com"

        assert conn.request_path ==
                 "/datacollectionRules/dcr-id/streams/Custom-Metrics-Otel/otlp/v1/metrics"

        assert conn.query_string == "test=1"
        assert get_req_header(conn, "authorization") == ["Bearer " <> token]
        assert get_req_header(conn, "content-type") == ["application/x-protobuf"]

        {:ok, body, conn} = read_body(conn)

        %{resource_metrics: [resource_metrics]} =
          :opentelemetry_exporter_metrics_service_pb.decode_msg(
            body,
            :export_metrics_service_request
          )

        assert resource_metrics.resource.attributes == [
                 %{key: "service.name", value: %{value: {:string_value, "portal"}}}
               ]

        [%{metrics: [metric]}] = resource_metrics.scope_metrics
        assert metric.name == "http.server.request.duration"
        {:histogram, histogram} = metric.data
        assert histogram.aggregation_temporality == :AGGREGATION_TEMPORALITY_DELTA

        assert [
                 %{
                   count: 6,
                   sum: 23.0,
                   min: 1.0,
                   max: 11.0,
                   bucket_counts: [2, 3, 1],
                   explicit_bounds: [2.0, 10.0]
                 }
               ] = histogram.data_points

        send_resp(conn, 200, "")
      end)

      assert MetricsExporter.export(metrics(), resource(), @endpoint) == :ok
    end
  end

  test "contains credential failures without logging token responses or sending metrics" do
    test_pid = self()

    Req.Test.expect(ManagedIdentity, fn conn ->
      conn |> put_status(500) |> Req.Test.json(%{"access_token" => "credential-secret"})
    end)

    Req.Test.stub(MetricsExporter, fn conn ->
      send(test_pid, :ingested)
      send_resp(conn, 200, "")
    end)

    log =
      capture_log(fn ->
        assert MetricsExporter.export(metrics(), resource(), @endpoint) == :failed_retryable
      end)

    assert log =~ "Azure metrics export failed"
    refute log =~ "credential-secret"
    refute_received :ingested
  end

  test "classifies rejected batches and does not follow redirects or log response bodies" do
    Req.Test.stub(ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "token",
        "expires_on" => System.system_time(:second) + 3600
      })
    end)

    for {status, result} <- [
          {302, :failed_not_retryable},
          {400, :failed_not_retryable},
          {429, :failed_retryable},
          {503, :failed_retryable}
        ] do
      Req.Test.expect(MetricsExporter, fn conn ->
        conn
        |> put_resp_header("location", "https://redirect.example.com/")
        |> send_resp(status, "response-secret")
      end)

      log =
        capture_log(fn ->
          assert MetricsExporter.export(metrics(), resource(), @endpoint) == result
        end)

      assert log =~ "Azure metrics export failed"
      refute log =~ "response-secret"
    end
  end

  test "does not fetch credentials or send an empty batch" do
    assert MetricsExporter.export([], resource(), @endpoint) == :ok
  end

  test "retries a transient ingest failure" do
    Portal.Config.put_env_override(:portal, MetricsExporter,
      req_opts: [
        plug: {Req.Test, MetricsExporter},
        retry: :transient,
        retry_delay: 0,
        max_retries: 1
      ]
    )

    Req.Test.expect(ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "token",
        "expires_on" => System.system_time(:second) + 3600
      })
    end)

    Req.Test.expect(MetricsExporter, fn conn -> send_resp(conn, 503, "") end)
    Req.Test.expect(MetricsExporter, fn conn -> send_resp(conn, 200, "") end)

    assert MetricsExporter.export(metrics(), resource(), @endpoint) == :ok
  end

  defp resource, do: :otel_resource.create(%{"service.name" => "portal"})

  defp metrics do
    [
      metric(
        name: "http.server.request.duration",
        scope: :opentelemetry.instrumentation_scope("portal", "1.0", :undefined),
        data:
          histogram(
            aggregation_temporality: :temporality_delta,
            datapoints: [
              histogram_datapoint(
                attributes: :otel_attributes.new(%{}, 128, 128),
                start_time: :opentelemetry.timestamp(),
                time: :opentelemetry.timestamp(),
                count: 6,
                sum: 23.0,
                min: 1.0,
                max: 11.0,
                bucket_counts: [2, 3, 1],
                explicit_bounds: [2.0, 10.0],
                exemplars: [],
                flags: 0
              )
            ]
          )
      )
    ]
  end
end
