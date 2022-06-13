defmodule FzVpn.Interface.WGAdapter do
  @moduledoc """
  This module determines by application environment which WireGuard adapter to
  use: `Live` or `Sandbox`.

  `Live` is used for environments where WireGuard is available and `Sandbox` is
  used for environments where it isn't.
  """

  def wg_adapter do
    Application.fetch_env!(:fz_vpn, :wg_adapter)
  end
end
