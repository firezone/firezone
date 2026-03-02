defmodule PortalWeb.Plugs.RateLimit do
  import Plug.Conn

  @default_refill_rate 10
  @default_capacity 200

  def init(opts), do: opts

  def call(conn, opts) do
    refill_rate = Keyword.get(opts, :refill_rate, config(:refill_rate, @default_refill_rate))
    capacity = Keyword.get(opts, :capacity, config(:capacity, @default_capacity))
    cost = Keyword.get(opts, :cost, PortalWeb.RateLimit.default_cost())

    key = "web:#{ip_to_string(conn.remote_ip)}"

    case PortalWeb.RateLimit.hit(key, refill_rate, capacity, cost) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end

  defp config(key, default) do
    Portal.Config.get_env(:portal, PortalWeb.RateLimit, [])
    |> Keyword.get(key, default)
  end

  defp ip_to_string(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end
end
