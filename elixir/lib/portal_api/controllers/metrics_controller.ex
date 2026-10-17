defmodule PortalAPI.MetricsController do
  @moduledoc """
  Receives OpenTelemetry metrics reported by gateways and forwards them to
  Azure Monitor, attributed to the gateway the report's token names.

  The endpoint speaks OTLP/HTTP with protobuf encoding: the body is an
  `ExportMetricsServiceRequest` and a success is an empty
  `ExportMetricsServiceResponse`. The report is forwarded before responding,
  so a gateway is only told it succeeded once Azure Monitor accepted it, and
  otherwise retains the report for its next attempt.
  """
  use PortalAPI, :controller

  require Logger

  alias PortalAPI.ProblemDetails

  @protobuf :opentelemetry_exporter_metrics_service_pb

  # Reports are a few hundred bytes. The OTLP spec only recommends a 64 MiB
  # ceiling, which is far more than a gateway ever needs to send.
  @max_body_bytes 1_000_000

  @resource_attributes [
    {"firezone.account.id", "account_id"},
    {"firezone.account.slug", "account_slug"},
    {"firezone.gateway.id", "gateway_id"},
    {"firezone.site.id", "site_id"},
    {"firezone.site.name", "site_name"}
  ]

  # Errors deviate from OTLP, which answers with a `google.rpc.Status`: the
  # portal speaks RFC 9457 problem details on every endpoint and gateways are
  # the only client here.
  def create(conn, _params) do
    claims = conn.assigns.metrics_claims

    with {:ok, body, conn} <- read_report(conn),
         {:ok, request} <- decode(body),
         request = attribute(request, claims),
         :ok <- Portal.Azure.Monitor.export_metrics(encode(request)) do
      conn
      |> put_resp_content_type("application/x-protobuf")
      |> send_resp(200, @protobuf.encode_msg(%{}, :export_metrics_service_response))
    else
      {:error, :too_large, conn} ->
        ProblemDetails.send(conn, 413, "Metrics report exceeds #{@max_body_bytes} bytes")

      {:error, :malformed} ->
        ProblemDetails.send(conn, 400, "Expected a protobuf ExportMetricsServiceRequest")

      {:error, reason} ->
        Logger.warning("Failed to forward gateway metrics",
          account_id: claims["account_id"],
          gateway_id: claims["gateway_id"],
          reason: inspect(reason)
        )

        {status, detail} = forward_error(reason)
        ProblemDetails.send(conn, status, detail)
    end
  end

  defp read_report(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(body) do
    {:ok, @protobuf.decode_msg(body, :export_metrics_service_request)}
  rescue
    _ -> {:error, :malformed}
  end

  defp encode(request), do: @protobuf.encode_msg(request, :export_metrics_service_request)

  # The resource is built from the verified claims alone, replacing whatever the
  # gateway sent, so a token holder cannot report into another gateway's or
  # another account's series.
  defp attribute(request, claims) do
    resource = %{
      attributes:
        Enum.map(@resource_attributes, fn {key, claim} ->
          %{key: key, value: %{value: {:string_value, to_string(Map.fetch!(claims, claim))}}}
        end)
    }

    Map.update(request, :resource_metrics, [], fn resource_metrics ->
      Enum.map(resource_metrics, &Map.put(&1, :resource, resource))
    end)
  end

  defp forward_error(%Req.TransportError{reason: :timeout}),
    do: {504, "Timed out forwarding the metrics report"}

  defp forward_error({:status, _status}), do: {502, "Failed to forward the metrics report"}
  defp forward_error(_reason), do: {503, "Metrics ingestion is unavailable"}
end
