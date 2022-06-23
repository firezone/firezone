defmodule FzVpn.Interface.WGAdapter do
  @moduledoc """
  This module determines by application environment which WireGuard adapter to
  use: `Live` or `Sandbox`.

  `Live` is used for environments where WireGuard is available and `Sandbox` is
  used for environments where it isn't.

  The `Sandbox` adapter is mocked with a simple GenServer to store state. When wg_adapter/0
  is called for the first time, it spawns the Sandbox GenServer and links it to the current
  process. This allows the current process to know which GenServer to call during tests.
  """

  # A little janky, but it works well.
  def wg_adapter do
    Application.fetch_env!(:fz_vpn, :wg_adapter)
  end
end
