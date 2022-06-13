defmodule FzVpn.Interface.WGAdapter.Sandbox do
  @moduledoc """
  The sandbox WireGuard adapter.
  """

  import Wireguardex.PeerConfigBuilder

  alias Wireguardex.PeerInfo
  alias Wireguardex.PeerStats

  require Logger

  @sandbox_device %{
    Application.compile_env!(:fz_vpn, :wireguard_interface_name) => %Wireguardex.Device{
      name: Application.compile_env!(:fz_vpn, :wireguard_interface_name),
      public_key: Application.compile_env!(:fz_vpn, :wireguard_public_key),
      listen_port: Application.compile_env!(:fz_vpn, :wireguard_port),
      peers: [
        %PeerInfo{
          config:
            peer_config()
            |> public_key("+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=")
            |> endpoint("140.82.48.115:54248")
            |> allowed_ips(["10.3.2.7/32", "fd00::3:2:7/128"]),
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
    Map.get(@sandbox_device, name)
  end

  def set_device(_config, _name) do
    :ok
  end

  def delete_device(_name) do
    :ok
  end

  def remove_peer(_name, _public_key) do
    :ok
  end
end
