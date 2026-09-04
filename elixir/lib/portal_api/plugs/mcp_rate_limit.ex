defmodule PortalAPI.Plugs.MCPRateLimit do
  @moduledoc """
  Limits the unauthenticated edge of the MCP endpoint by source IP.

  OAuth token verification and JSON decoding both happen later in the
  pipeline, so invalid credentials and oversized or malformed bodies cannot be
  used to bypass this inexpensive first line of defense.
  """

  import Plug.Conn

  @cost 1

  def init(opts), do: opts

  def call(conn, opts) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    refill_rate = Keyword.get(opts, :refill_rate, Keyword.fetch!(config, :refill_rate))
    capacity = Keyword.get(opts, :capacity, Keyword.fetch!(config, :capacity))
    key = "mcp:ip:#{ip_to_string(conn.remote_ip)}"

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, @cost) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        retry_after = max(ceil(retry_after_ms / 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> PortalAPI.ProblemDetails.send(429, "Rate limit exceeded, retry after #{retry_after}s")
    end
  end

  defp ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()
end
