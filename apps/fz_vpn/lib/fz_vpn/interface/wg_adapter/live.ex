defmodule FzVpn.Interface.WGAdapter.Live do
  @moduledoc """
  The live WireGuard adapter.
  """

  use GenServer

  # Stub out a GenServer start and init for now.
  # Track state around the WireGuard calls if needed later.

  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  @impl GenServer
  def init(_), do: {:ok, %{}}

  def get_device(name) do
    Wireguardex.get_device(name)
  end

  def set_device(config, name) do
    Wireguardex.set_device(config, name)
  end

  def delete_device(name) do
    Wireguardex.delete_device(name)
  end

  def remove_peer(name, public_key) do
    Wireguardex.remove_peer(name, public_key)
  end
end
