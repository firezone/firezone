defmodule FzVpn.Config do
  @moduledoc """
  Functions for managing the WireGuard configuration.
  """

  # Render peers list into server config
  def render(config) do
    Enum.join(
      for {public_key, {ipv4, ipv6}} <- config do
        "peer #{public_key} allowed-ips #{ipv4}/32,#{ipv6}/128"
      end,
      " "
    )
  end
end
