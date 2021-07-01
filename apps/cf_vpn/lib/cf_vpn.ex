defmodule CfVpn do
  @moduledoc """
  Documentation for `CfVpn`.
  """
  use Rustler, otp_app: :cf_vpn

  def add(_arg1, _arg2), do: :erlang.nif_error(:nif_not_loaded)
end
