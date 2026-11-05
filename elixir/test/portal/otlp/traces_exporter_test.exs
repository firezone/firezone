defmodule Portal.OTLP.TracesExporterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  require Record

  alias Portal.Azure.ManagedIdentity
  alias Portal.OTLP.TracesExporter

  @moduletag capture_log: true

  @endpoint "https://traces.example.com/v1/traces"

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

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

  describe "export/3" do
    test "posts error spans and spans of traces in the sampled bucket" do
      in_bucket = 1
      out_of_bucket = 0x7FFFFFFFFFFFFFFF

      spans = [
        span_record(1, in_bucket, :unset),
        span_record(2, in_bucket + Bitwise.bsl(1, 100), :unset),
        span_record(3, out_of_bucket, :error),
        span_record(4, out_of_bucket, :ok),
        span_record(5, out_of_bucket, :unset)
      ]

      test_pid = self()

      Req.Test.expect(TracesExporter, fn conn ->
        {:ok, body, conn} = read_body(conn)
        send(test_pid, {:request, conn, body})
        send_resp(conn, 200, "")
      end)

      assert export(spans) == :ok

      assert_received {:request, conn, body}
      assert conn.method == "POST"
      assert get_req_header(conn, "authorization") == ["Bearer token"]
      assert get_req_header(conn, "content-type") == ["application/x-protobuf"]

      request =
        :opentelemetry_exporter_trace_service_pb.decode_msg(body, :export_trace_service_request)

      span_ids =
        for resource_spans <- request.resource_spans,
            scope_spans <- resource_spans.scope_spans,
            span <- scope_spans.spans,
            do: :binary.decode_unsigned(span.span_id)

      assert Enum.sort(span_ids) == [1, 2, 3]
    end

    test "does not post when no span is sampled" do
      assert export([span_record(1, 0x7FFFFFFFFFFFFFFF, :unset)]) == :ok
    end

    test "classifies export response status codes" do
      for {status, result} <- [
            {200, :ok},
            {202, :ok},
            {302, :failed_not_retryable},
            {400, :failed_not_retryable},
            {401, :failed_not_retryable},
            {408, :failed_retryable},
            {429, :failed_retryable},
            {500, :failed_retryable},
            {503, :failed_retryable}
          ] do
        Req.Test.expect(TracesExporter, fn conn -> send_resp(conn, status, "") end)

        assert export([span_record(1, 1, :unset)]) == result
      end
    end
  end

  defp export(spans) do
    tab = :ets.new(:spans, [:duplicate_bag, keypos: span(:instrumentation_scope) + 1])
    :ets.insert(tab, spans)
    {:ok, state} = TracesExporter.init(%{endpoint: @endpoint, auth: :azure_managed_identity})
    TracesExporter.export(tab, :otel_resource.create(%{}), state)
  end

  defp span_record(span_id, trace_id, status_code) do
    now = :opentelemetry.timestamp()

    span(
      trace_id: trace_id,
      span_id: span_id,
      name: "span",
      kind: :internal,
      start_time: now,
      end_time: now,
      attributes: :otel_attributes.new(%{}, 128, :infinity),
      events: :otel_events.new(128, 128, :infinity),
      links: :otel_links.new([], 128, 128, :infinity),
      status: :opentelemetry.status(status_code, ""),
      instrumentation_scope: :opentelemetry.instrumentation_scope("portal", "1.0", :undefined)
    )
  end
end
