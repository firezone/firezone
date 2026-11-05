defmodule Portal.OTLP do
  @moduledoc """
  Shared transport of the portal's OTLP/HTTP exporters.
  """

  require Logger

  @azure_monitor_resource "https://monitor.azure.com/"

  @doc """
  Builds the `:opentelemetry` span processors for the configured trace exporters.
  """
  def trace_processors(collector_endpoint, traces_endpoint, auth) do
    # The SDK skips later processors for a span once one drops it, so keep the collector first.
    exporters = [
      if(collector_endpoint, do: {:opentelemetry_exporter, %{}}),
      if(traces_endpoint,
        do: {Portal.OTLP.TracesExporter, %{endpoint: traces_endpoint, auth: auth}}
      )
    ]

    for exporter <- exporters, not is_nil(exporter) do
      {:otel_batch_processor, %{exporter: exporter}}
    end
  end

  @doc """
  Posts an encoded OTLP request and classifies the response for the SDK.
  """
  def post(endpoint, body, auth, req_opts) do
    opts =
      Keyword.merge(req_opts,
        body: body,
        headers: [{"content-type", "application/x-protobuf"} | headers(auth)],
        redirect: false,
        retry_log_level: false
      )

    case Req.post(endpoint, opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("OTLP export failed", status: status)

        if status in [408, 429, 500, 502, 503, 504],
          do: :failed_retryable,
          else: :failed_not_retryable

      {:error, _reason} ->
        Logger.warning("OTLP export request failed")
        :failed_retryable
    end
  end

  defp headers({:headers, headers}), do: headers

  defp headers(:azure_managed_identity) do
    token = Portal.Azure.ManagedIdentity.access_token!(@azure_monitor_resource)
    [{"authorization", "Bearer " <> token}]
  end
end
