defmodule FgVpn.Server do
  @moduledoc """
  Module to load boringtun lib as a server
  """

  use Rustler, otp_app: :fg_vpn, crate: :fgvpn_server

  def add(_arg1, _arg2), do: :erlang.nif_error(:nif_not_loaded)
end
