defmodule PortalAPI.Plugs.RateLimit do
  import Plug.Conn

  @refill_rate_default Portal.Config.fetch_env!(:portal, PortalAPI.RateLimit)[:refill_rate]
  @capacity_default Portal.Config.fetch_env!(:portal, PortalAPI.RateLimit)[:capacity]
  @cost_default PortalAPI.RateLimit.default_cost()
  @skip_key :portal_api_skip_rate_limit

  @doc "Private key used by an already-metered internal dispatch."
  def skip_key, do: @skip_key

  def init(opts), do: opts

  def call(%Plug.Conn{private: %{@skip_key => true}} = conn, _opts), do: conn

  def call(conn, opts) do
    rate_limit_api(conn, opts)
  end

  defp rate_limit_api(conn, opts) do
    account = conn.assigns.subject.account
    key = "api:#{account.id}"
    refill_rate = refill_rate(account)
    capacity = capacity(account)

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, @cost_default) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        if Keyword.get(opts, :mcp, false) do
          PortalAPI.ProblemDetails.rate_limited(conn, retry_after_ms)
        else
          conn
          |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
          |> PortalAPI.ProblemDetails.send(
            429,
            "Rate limit exceeded. Retry after the time indicated in the Retry-After header."
          )
        end
    end
  end

  defp refill_rate(account) do
    account.limits.api_refill_rate || @refill_rate_default
  end

  defp capacity(account) do
    account.limits.api_capacity || @capacity_default
  end
end
