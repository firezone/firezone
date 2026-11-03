defmodule PortalAPI.Plugs.MetricsRateLimit do
  @moduledoc """
  Rate limits `POST /v1/metrics` by source IP (`by: :ip`, before authentication)
  or by the token's account (`by: :account`, after `PortalAPI.Plugs.MetricsAuth`).
  """

  @cost 1

  def init(opts), do: Keyword.fetch!(opts, :by)

  def call(conn, by) do
    limits = Portal.Config.fetch_env!(:portal, __MODULE__) |> Keyword.fetch!(by)

    case PortalAPI.RateLimit.hit(key(conn, by), limits[:refill_rate], limits[:capacity], @cost) do
      {:allow, _count} -> conn
      {:deny, retry_after_ms} -> PortalAPI.ProblemDetails.rate_limited(conn, retry_after_ms)
    end
  end

  defp key(conn, :ip), do: "otlp_metrics:ip:#{:inet.ntoa(conn.remote_ip)}"
  defp key(conn, :account), do: "otlp_metrics:account:#{conn.assigns.metrics_claims["account_id"]}"
end
