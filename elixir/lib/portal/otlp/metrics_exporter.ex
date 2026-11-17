defmodule Portal.OTLP.MetricsExporter do
  @moduledoc false
  @behaviour :otel_exporter_metrics

  require Logger

  @impl true
  def init(%{endpoint: _, auth: _} = state), do: {:ok, state}

  @impl true
  def export([], _resource, _state), do: :ok

  def export(metrics, resource, %{endpoint: endpoint, auth: auth}) do
    body =
      metrics
      |> :otel_otlp_metrics.to_proto(resource)
      |> :opentelemetry_exporter_metrics_service_pb.encode_msg(:export_metrics_service_request)

    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    Portal.OTLP.post(endpoint, body, auth, config[:req_opts])
  rescue
    _exception ->
      Logger.warning("OTLP metrics export failed")
      :failed_retryable
  end

  @impl true
  def shutdown(_state), do: :ok
end
