defmodule PortalAPI.Plugs.IngestionRateLimit do
  import Plug.Conn

  @default_refill_rate Portal.Config.fetch_env!(:portal, PortalAPI.RateLimit)[:refill_rate]
  @default_capacity Portal.Config.fetch_env!(:portal, PortalAPI.RateLimit)[:capacity]
  @cost 1

  def init(opts), do: opts

  def call(conn, _opts) do
    account = conn.assigns.account
    token_id = conn.assigns.token_id
    ip_key = "ingestion:ip:#{ip_to_string(conn.remote_ip)}"
    token_key = "ingestion:token:#{token_id}"
    refill_rate = refill_rate(account)
    capacity = capacity(account)

    with {:allow, _} <- PortalAPI.RateLimit.hit(ip_key, refill_rate, capacity, @cost),
         {:allow, _} <- PortalAPI.RateLimit.hit(token_key, refill_rate, capacity, @cost) do
      conn
    else
      {:deny, retry_after_ms} ->
        retry_after = max(ceil(retry_after_ms / 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> PortalAPI.ProblemDetails.send(429, "Rate limit exceeded, retry after #{retry_after}s")
    end
  end

  defp refill_rate(account) do
    account.limits.ingestion_refill_rate || @default_refill_rate
  end

  defp capacity(account) do
    account.limits.ingestion_capacity || @default_capacity
  end

  defp ip_to_string(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end
end
