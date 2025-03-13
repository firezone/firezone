defmodule API.Plugs.RateLimit do
  import Plug.Conn

  @refill_rate_default Domain.Config.fetch_env!(:api, API.RateLimit)[:refill_rate]
  @capacity_default Domain.Config.fetch_env!(:api, API.RateLimit)[:capacity]
  @cost_default API.RateLimit.default_cost()

  def init(opts), do: Keyword.get(opts, :context_type, :api_client)

  def call(conn, _context_type) do
    rate_limit_api(conn, [])
  end

  defp rate_limit_api(conn, _opts) do
    account = conn.assigns.subject.account
    key = "api:#{account.id}"
    refill_rate = refill_rate(account)
    capacity = capacity(account)

    case API.RateLimit.hit(key, refill_rate, capacity, @cost_default) do
      {:allow, _count} ->
        conn

      {:deny, _refill_time} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(@cost_default, refill_rate)))
        |> put_status(429)
        |> Phoenix.Controller.put_view(json: API.ErrorJSON)
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
