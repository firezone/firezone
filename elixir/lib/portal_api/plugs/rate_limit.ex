defmodule PortalAPI.Plugs.RateLimit do
  import Plug.Conn

  @config Portal.Config.fetch_env!(:portal, PortalAPI.RateLimit)
  @refill_rate_default @config[:refill_rate]
  @capacity_default @config[:capacity]
  @read_refill_rate_default @config[:read_refill_rate]
  @read_capacity_default @config[:read_capacity]
  @cost_default PortalAPI.RateLimit.default_cost()
  @skip_key :portal_api_skip_rate_limit
  @mcp_dispatch_key :portal_api_mcp_dispatch

  @doc "Private key used by an already-metered internal dispatch."
  def skip_key, do: @skip_key

  @doc "Private key that marks an MCP tool call re-entering the REST pipeline."
  def mcp_dispatch_key, do: @mcp_dispatch_key

  def init(opts), do: opts

  def call(%Plug.Conn{private: %{@skip_key => true}} = conn, _opts), do: conn

  def call(conn, opts) do
    rate_limit_api(conn, opts)
  end

  defp rate_limit_api(conn, opts) do
    account = conn.assigns.subject.account
    {key, refill_rate, capacity} = bucket(conn, account, opts)

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, @cost_default) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        if Keyword.get(opts, :mcp, false) or Map.has_key?(conn.private, @mcp_dispatch_key) do
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

  # The body of an /mcp request is not parsed yet, so it is charged as a read.
  # A write tool call is charged again to the write bucket when it re-enters
  # the REST pipeline.
  defp bucket(conn, account, opts) do
    if conn.method == "GET" or Keyword.get(opts, :mcp, false) do
      read_bucket(account)
    else
      write_bucket(account)
    end
  end

  defp read_bucket(account) do
    limits = account.limits

    {
      "api:read:#{account.id}",
      limits.api_read_refill_rate || limits.api_refill_rate || @read_refill_rate_default,
      limits.api_read_capacity || limits.api_capacity || @read_capacity_default
    }
  end

  defp write_bucket(account) do
    {
      "api:#{account.id}",
      account.limits.api_refill_rate || @refill_rate_default,
      account.limits.api_capacity || @capacity_default
    }
  end
end
