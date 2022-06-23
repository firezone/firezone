defmodule FzVpn.Interface.WGAdapter.Sandbox do
  @moduledoc """
  The sandbox WireGuard adapter.
  """

  use GenServer

  @adapter_pid :sandbox_adapter_pid

  def get_device(name) do
    GenServer.call(sandbox_pid(), {:get_device, name})
  end

  def list_devices do
    GenServer.call(sandbox_pid(), {:list_devices})
  end

  def set_device(config, name) do
    GenServer.call(sandbox_pid(), {:set_device, config, name})
  end

  def delete_device(name) do
    GenServer.call(sandbox_pid(), {:delete_device, name})
  end

  def remove_peer(name, public_key) do
    GenServer.call(sandbox_pid(), {:remove_peer, name, public_key})
  end

  defp sandbox_pid do
    case Process.get(@adapter_pid) do
      nil ->
        {:ok, pid} = GenServer.start_link(__MODULE__, %{})
        Process.put(@adapter_pid, pid)
        pid

      pid ->
        pid
    end
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
  def handle_call({:list_devices}, _from, devices) do
    {:reply, {:ok, Map.keys(devices)}, devices}
  end

  @impl GenServer
  def handle_call({:set_device, config, name}, _from, devices) do
    public_key =
      if config.private_key do
        {:ok, public_key} = Wireguardex.get_public_key(config.private_key)
        public_key
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
