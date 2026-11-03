defmodule PortalAPI.Plugs.IntegrationsRateLimit do
  @moduledoc """
  Per-IP rate limit for the public webhook endpoints under `/integrations`.

  It runs before anything reads the body or touches the database.
  """

  import Plug.Conn
  require Logger

  @cost 1

  def init(opts), do: opts

  def call(conn, opts) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    refill_rate = Keyword.get(opts, :refill_rate, Keyword.fetch!(config, :refill_rate))
    capacity = Keyword.get(opts, :capacity, Keyword.fetch!(config, :capacity))
    key = "integrations:ip:#{conn.remote_ip |> :inet.ntoa() |> to_string()}"

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, @cost) do
      {:allow, _} ->
        conn

      {:deny, retry_after_ms} ->
        Logger.warning("Webhook rate limit exceeded")

        conn
        |> put_resp_header("retry-after", Integer.to_string(max(ceil(retry_after_ms / 1000), 1)))
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end
end
