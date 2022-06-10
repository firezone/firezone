defmodule FzVpn.Interface.WGAdapter do
  @moduledoc false

  def wg_adapter() do
    Application.fetch_env!(:fz_vpn, :wg_adapter)
  end
end
