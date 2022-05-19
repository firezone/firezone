defmodule FzVpn.CLI.Wireguard do
  use Rustler, otp_app: :fz_vpn, crate: "wireguard_nif"

  def set(_config_str, _name), do: error()
  def show(_subcommand, _name), do: error()

  defp error(), do: :erlang.nif_error(:nif_not_loaded)
end
