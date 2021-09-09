defmodule FzVpn.Config do
  @moduledoc """
  Functions for managing the WireGuard configuration.
  """

  defstruct peers: MapSet.new([])

  def render(config) do
    Enum.join(
      for peer <- config.peers do
        "peer #{peer.public_key} allowed-ips #{peer.allowed_ips}"
      end,
      " "
    )
  end
end
