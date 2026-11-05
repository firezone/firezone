defmodule Portal.OTLPTest do
  use ExUnit.Case, async: true

  alias Portal.OTLP

  @collector "http://10.0.0.1:4318"
  @traces "https://otlp.example.com/v1/traces"
  @auth {:headers, []}

  describe "trace_processors/3" do
    test "returns no processors without endpoints" do
      assert OTLP.trace_processors(nil, nil, @auth) == []
    end

    test "exports to the collector" do
      assert OTLP.trace_processors(@collector, nil, @auth) == [
               {:otel_batch_processor, %{exporter: {:opentelemetry_exporter, %{}}}}
             ]
    end

    test "exports to the traces endpoint" do
      assert OTLP.trace_processors(nil, @traces, @auth) == [
               {:otel_batch_processor,
                %{exporter: {OTLP.TracesExporter, %{endpoint: @traces, auth: @auth}}}}
             ]
    end

    test "exports to the collector first, then the traces endpoint" do
      assert OTLP.trace_processors(@collector, @traces, @auth) == [
               {:otel_batch_processor, %{exporter: {:opentelemetry_exporter, %{}}}},
               {:otel_batch_processor,
                %{exporter: {OTLP.TracesExporter, %{endpoint: @traces, auth: @auth}}}}
             ]
    end
  end
end
