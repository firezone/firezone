defmodule FzVpn.Config do
  @moduledoc """
  Functions for managing the WireGuard configuration.
  """

  # Render peers list into server config
  def render(config) do
    Enum.join(
      for {public_key, allowed_ips} <- config do
        "peer #{public_key} allowed-ips #{allowed_ips}"
      end,
      " "
    )
  end
end
