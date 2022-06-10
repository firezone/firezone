defmodule FzVpn.Interface.WGAdapter.Sandbox do
  @moduledoc """
  The live WireGuard adapter.
  """

  import Wireguardex.PeerConfigBuilder

  alias Wireguardex.PeerInfo
  alias Wireguardex.PeerStats

  require Logger

  @devices %{
    Application.fetch_env!(:fz_vpn, :wireguard_interface_name) => %Wireguardex.Device{
      name: Application.fetch_env!(:fz_vpn, :wireguard_interface_name),
      public_key: Application.fetch_env!(:fz_vpn, :wireguard_public_key),
      listen_port: Application.fetch_env!(:fz_vpn, :wireguard_port),
      peers: [
        %PeerInfo{
          config:
            peer_config()
            |> public_key("+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=")
            |> endpoint("140.82.48.115:54248")
            |> allowed_ips(["10.3.2.7/32", "fd00::3::2::7/128"]),
          stats: %PeerStats{
            last_handshake_time: 1_650_286_790,
            rx_bytes: 14_161_600,
            tx_bytes: 3_668_160
          }
        },
        %PeerInfo{
          config:
            peer_config()
            |> public_key("JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY=")
            |> endpoint("149.28.197.67:44491")
            |> allowed_ips(["10.3.2.8/32", "fd00::3:2:8/128"]),
          stats: %PeerStats{
            last_handshake_time: 1_650_286_747,
            rx_bytes: 177_417_128,
            tx_bytes: 138_272_552
          }
        }
      ]
    }
  }

  def get_device(name) do
    Map.get(@devices, name)
  end

  def set_device(config, name) do
    Map.put(@devices, name, %Wireguardex.Device{
      name: name,
      public_key: config.public_key,
      private_key: config.private_key,
      fwmark: config.fwmark,
      listen_port: config.listen_port,
      peers:
        config.peers
        |> Enum.map(fn peer ->
          %PeerInfo{
            config: peer,
            stats: %PeerStats{last_handshake_time: 0, rx_bytes: 0, tx_bytes: 0}
          }
        end)
    })

    :ok
  end

  def delete_device(name) do
    Map.delete(@devices, name)

    :ok
  end

  def remove_peer(name, _public_key) do
    _device = Map.get(@devices, name)

    :ok
  end
end
