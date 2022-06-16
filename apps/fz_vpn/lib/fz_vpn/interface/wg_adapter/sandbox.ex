defmodule FzVpn.Interface.WGAdapter.Sandbox do
  @moduledoc """
  The sandbox WireGuard adapter.
  """

  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_device(name) do
    {:ok, device} = GenServer.call(__MODULE__, {:get_device, name})
    device
  end

  def set_device(config, name) do
    GenServer.call(__MODULE__, {:set_device, config, name})
  end

  def delete_device(name) do
    GenServer.call(__MODULE__, {:delete_device, name})
  end

  def remove_peer(name, public_key) do
    GenServer.call(__MODULE__, {:remove_peer, name, public_key})
  end

  @impl GenServer
  def init(_) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:get_device, name}, _from, devices) do
    {:reply, {:ok, Map.get(devices, name)}, devices}
  end

  @impl GenServer
  def handle_call({:set_device, config, name}, _from, devices) do
    public_key =
      if config.private_key do
        Wireguardex.get_public_key(config.private_key)
      end

    peers =
      config.peers
      |> Enum.map(fn peer ->
        %Wireguardex.PeerInfo{
          config: peer,
          stats: %Wireguardex.PeerStats{}
        }
      end)

    device = %Wireguardex.Device{
      name: name,
      public_key: public_key,
      private_key: config.private_key,
      listen_port: config.listen_port,
      peers: peers
    }

    {:reply, :ok, Map.put(devices, name, device)}
  end

  @impl GenServer
  def handle_call({:delete_device, name}, _from, devices) do
    {:reply, :ok, Map.delete(devices, name)}
  end

  @impl GenServer
  def handle_call({:remove_peer, name, public_key}, _from, devices) do
    device = Map.get(devices, name)

    peers =
      Enum.reject(device.peers, fn peer ->
        peer.config.public_key == public_key
      end)

    new_device = %Wireguardex.Device{
      name: device.name,
      public_key: device.public_key,
      private_key: device.private_key,
      fwmark: device.fwmark,
      listen_port: device.listen_port,
      peers: peers,
      linked_name: device.linked_name
    }

    {:reply, :ok, Map.put(devices, name, new_device)}
  end
end
