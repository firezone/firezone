defmodule PortalAPI.Plugs.RateLimit do
  import Plug.Conn

  @refill_rate_default Portal.Config.fetch_env!(:api, PortalAPI.RateLimit)[:refill_rate]
  @capacity_default Portal.Config.fetch_env!(:api, PortalAPI.RateLimit)[:capacity]
  @cost_default PortalAPI.RateLimit.default_cost()

  def init(opts), do: Keyword.get(opts, :context_type, :api_client)

  def call(conn, _context_type) do
    rate_limit_api(conn, [])
  end

  defp rate_limit_api(conn, _opts) do
    account = conn.assigns.subject.account
    key = "api:#{account.id}"
    refill_rate = refill_rate(account)
    capacity = capacity(account)

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, @cost_default) do
      {:allow, _count} ->
        conn

      {:deny, _refill_time} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(@cost_default, refill_rate)))
        |> put_status(429)
        |> Phoenix.Controller.put_view(json: PortalAPI.ErrorJSON)
        |> Phoenix.Controller.render(:"429")
        |> halt()
    end
  end

  defp refill_rate(account) do
    Map.get(account.limits, :api_refill_rate, @refill_rate_default)
  end

  defp capacity(account) do
    Map.get(account.limits, :api_capacity, @capacity_default)
  end
end
