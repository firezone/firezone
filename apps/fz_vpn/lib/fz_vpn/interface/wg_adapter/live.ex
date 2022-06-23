defmodule FzVpn.Interface.WGAdapter.Live do
  @moduledoc """
  The live WireGuard adapter.
  """

  defdelegate get_device(name), to: Wireguardex
  defdelegate list_devices, to: Wireguardex
  defdelegate set_device(config, name), to: Wireguardex
  defdelegate delete_device(name), to: Wireguardex
  defdelegate remove_peer(name, public_key), to: Wireguardex
end
