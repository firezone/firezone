defmodule Portal.OTLP.TracesExporter do
  @moduledoc false
  @behaviour :otel_exporter_traces

  require Logger
  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecordp(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  # Same bucketing as `otel_sampler_trace_id_ratio_based`.
  @trace_id_mask 0x7FFFFFFFFFFFFFFF

  @impl true
  def init(%{endpoint: _, auth: _} = state), do: {:ok, state}

  @impl true
  def export(spans, resource, %{endpoint: endpoint, auth: auth}) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    id_upper_bound = config[:sample_ratio] * @trace_id_mask

    sampled = :ets.new(__MODULE__, [:duplicate_bag, keypos: span(:instrumentation_scope) + 1])

    try do
      :ets.insert(
        sampled,
        Enum.filter(:ets.tab2list(spans), &sampled?(&1, id_upper_bound))
      )

      case :otel_otlp_traces.to_proto(sampled, resource) do
        :empty -> :ok
        proto -> post(endpoint, proto, auth, config)
      end
    after
      :ets.delete(sampled)
    end
  rescue
    _exception ->
      Logger.warning("OTLP traces export failed")
      :failed_retryable
  end

  @impl true
  def shutdown(_state), do: :ok

  defp sampled?(span(status: status(code: :error)), _id_upper_bound), do: true

  defp sampled?(span(trace_id: trace_id), id_upper_bound),
    do: Bitwise.band(trace_id, @trace_id_mask) < id_upper_bound

  defp post(endpoint, proto, auth, config) do
    body = :opentelemetry_exporter_trace_service_pb.encode_msg(proto, :export_trace_service_request)

    Portal.OTLP.post(endpoint, body, auth, config[:req_opts])
  end
end
