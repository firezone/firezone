defmodule Portal.Azure.MetricsExporter do
  @moduledoc false
  @behaviour :otel_exporter_metrics

  require Logger

  @resource "https://monitor.azure.com/"

  @impl true
  def init(%{endpoint: endpoint}) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        {:ok, endpoint}

      _ ->
        raise ArgumentError, "AZURE_OTLP_METRICS_ENDPOINT must be a full HTTPS URL"
    end
  end

  @impl true
  def export([], _resource, _endpoint), do: :ok

  def export(metrics, resource, endpoint) do
    body =
      metrics
      |> :otel_otlp_metrics.to_proto(resource)
      |> :opentelemetry_exporter_metrics_service_pb.encode_msg(:export_metrics_service_request)

    token = Portal.Azure.ManagedIdentity.access_token!(@resource)
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    opts =
      Keyword.merge(config[:req_opts],
        body: body,
        headers: [
          {"authorization", "Bearer " <> token},
          {"content-type", "application/x-protobuf"}
        ],
        redirect: false,
        retry_log_level: false
      )

    case Req.post(endpoint, opts) do
      {:ok, %{status: status}} when status in 200..202 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("Azure metrics export failed", status: status)

        if status in [408, 429, 500, 502, 503, 504],
          do: :failed_retryable,
          else: :failed_not_retryable

      {:error, _reason} ->
        Logger.warning("Azure metrics export request failed")
        :failed_retryable
    end
  rescue
    _exception ->
      Logger.warning("Azure metrics export failed")
      :failed_retryable
  end

  @impl true
  def shutdown(_endpoint), do: :ok
end
