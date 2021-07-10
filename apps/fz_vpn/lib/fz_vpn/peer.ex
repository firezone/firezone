defmodule FzVpn.Peer do
  @moduledoc """
  Represents a WireGuard peer.
  """

  defstruct public_key: nil,
            allowed_ips: "0.0.0.0/0,::/0",
            preshared_key: nil
end
