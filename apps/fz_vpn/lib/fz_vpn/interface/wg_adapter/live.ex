defmodule FzVpn.Interface.WGAdapter.Live do
  @moduledoc """
  The live WireGuard adapter.
  """

  use GenServer

  defdelegate get_device(name), to: Wireguardex
  defdelegate list_devices, to: Wireguardex
  defdelegate set_device(config, name), to: Wireguardex
  defdelegate delete_device(name), to: Wireguardex
  defdelegate remove_peer(name, public_key), to: Wireguardex

  # Stub out a GenServer start and init for now.
  # Track state around the WireGuard calls if needed later.

  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  @impl GenServer
  def init(_), do: {:ok, %{}}
end
