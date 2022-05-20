defmodule FzVpn.WireguardBridge do
  @moduledoc """
  NIFs implemented in Rust to interact with Wireguard from Elixir
  """

  use Rustler, otp_app: :fz_vpn, crate: "wireguard_nif"

  def set(_config, _name), do: error()
  def show(_subcommand, _name), do: error()

  defp error(), do: :erlang.nif_error(:nif_not_loaded)
end
