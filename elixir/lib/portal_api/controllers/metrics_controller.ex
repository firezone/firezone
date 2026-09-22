defmodule PortalAPI.MetricsController do
  @moduledoc """
  Receives OpenTelemetry metrics exported by gateways.

  The endpoint speaks OTLP/HTTP with JSON encoding: the body is an
  `ExportMetricsServiceRequest` and a success is an empty
  `ExportMetricsServiceResponse`, which means every data point was accepted.
  Nothing is persisted yet; reports are logged.
  """
  use PortalAPI, :controller

  require Logger

  alias PortalAPI.ProblemDetails

  # Errors deviate from OTLP, which answers with a `google.rpc.Status`: the
  # portal speaks RFC 9457 problem details on every endpoint and gateways are
  # the only client here.
  def create(conn, params) do
    claims = conn.assigns.metrics_claims

    case PortalAPI.OTLP.data_points(params) do
      {:ok, data_points} ->
        Enum.each(data_points, &log_data_point(&1, claims))

        conn
        |> put_status(200)
        |> json(%{})

      :error ->
        ProblemDetails.send(conn, 400, "Expected an OTLP ExportMetricsServiceRequest")
    end
  end

  defp log_data_point(data_point, claims) do
    Logger.debug("Received gateway metric",
      account_id: claims["account_id"],
      gateway_id: claims["gateway_id"],
      site_id: claims["site_id"],
      metric: data_point.name,
      value: data_point.value,
      attributes: inspect(data_point.attributes),
      time_unix_nano: data_point.time_unix_nano
    )
  end
end
