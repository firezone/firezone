defmodule PortalWeb.PublicEmailRateLimit do
  @moduledoc """
  Per-IP and global limits for emails that public forms send to an address the
  visitor types. LiveView events bypass `PortalWeb.Plugs.RateLimit`.
  """

  # Hammer refills whole tokens per second, so one email costs an hour of tokens.
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

  # One host usually controls its whole IPv6 /64.
  defp ip_key({a, b, c, d, _, _, _, _}),
    do: ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string()) <> "/64"
end
