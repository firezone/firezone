defmodule PortalWeb.PublicEmailRateLimit do
  @moduledoc """
  Limits the emails that visitors without a session can make the portal send,
  for example from the find account and sign up forms.

  These forms submit LiveView events over the WebSocket, so
  `PortalWeb.Plugs.RateLimit` does not see them. The per-address limit in
  `Portal.Mailer.deliver_with_rate_limit/2` does not help when each request uses
  a different address. Call `check/2` before such an email is sent.

  Each scope has one bucket per client address and one global bucket. IPv6
  clients share a bucket per /64 prefix, because one host can usually use all
  addresses in its /64. The buckets replicate through `PortalWeb.RateLimit`, so
  they are eventually consistent across nodes.
  """

  # Hammer refills whole tokens per second. When one email costs one hour of
  # tokens, a refill rate of N gives N emails per hour.
  @cost 3_600

  @spec check(atom(), :inet.ip_address()) :: :ok | {:error, :rate_limited}
  def check(scope, ip) when is_atom(scope) do
    config = Portal.Config.get_env(:portal, __MODULE__, [])

    with :ok <- hit("public_email:#{scope}:ip:#{ip_key(ip)}", Keyword.fetch!(config, :per_ip_per_hour)) do
      hit("public_email:#{scope}:global", Keyword.fetch!(config, :global_per_hour))
    end
  end

  defp hit(key, per_hour) do
    case PortalWeb.RateLimit.hit(key, per_hour, per_hour * @cost, @cost) do
      {:allow, _remaining} -> :ok
      {:deny, _retry_after_ms} -> {:error, :rate_limited}
    end
  end

  defp ip_key({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp ip_key({a, b, c, d, _, _, _, _}),
    do: ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string()) <> "/64"
end
