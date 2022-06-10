defmodule FzVpn.Interface do
  @moduledoc """
  This module has functions to create interfaces, set configurations on them,
  and get peer info via [WireGuard](https://wireguard.com)
  """
  import FzCommon.CLI
  import FzVpn.Interface.WGAdapter
  import Wireguardex.DeviceConfigBuilder, except: [public_key: 2]
  import Wireguardex.PeerConfigBuilder, except: [public_key: 2]

  alias Wireguardex.DeviceConfigBuilder
  alias Wireguardex.PeerConfigBuilder

  require Logger

  def create(name, listen_port, ipv4_address, ipv6_address, mtu) do
    private_key = Wireguardex.generate_private_key()
    public_key = Wireguardex.get_public_key(private_key)

    result =
      DeviceConfigBuilder.device_config()
      |> listen_port(listen_port)
      |> private_key(private_key)
      |> DeviceConfigBuilder.public_key(public_key)
      |> wg_adapter().set_device(name)

    case result do
      :ok ->
        ip_cmds(name, ipv4_address, ipv6_address, mtu)
        {:ok, {private_key, public_key}}

      {:error, error_info} ->
        Logger.warn("Failed to create interface #{name}: #{error_info}")
        result
    end
  end

  def set(name, private_key, peers) do
    peer_configs =
      for public_key <- Map.keys(peers) do
        settings = Map.get(peers, public_key)
        preshared_key = settings.preshared_key
        allowed_ips = String.split(settings.allowed_ips, ",")

        PeerConfigBuilder.peer_config()
        |> PeerConfigBuilder.public_key(public_key)
        |> preshared_key(preshared_key)
        |> allowed_ips(allowed_ips)
      end

    result =
      DeviceConfigBuilder.device_config()
      |> private_key(private_key)
      |> peers(peer_configs)
      |> wg_adapter().set_device(name)

    case result do
      :ok ->
        :ok

      {:error, error_info} ->
        Logger.warn("Failed to set interface #{name}: #{error_info}")
        result
    end
  end

  def delete_interface(name) do
    result = wg_adapter().delete_device(name)

    case result do
      :ok ->
        :ok

      {:error, error_info} ->
        Logger.warn("Failed to delete interface #{name}: #{error_info}")
        result
    end
  end

  def remove_peer(name, public_key) do
    result = wg_adapter().remove_peer(name, public_key)

    case result do
      :ok ->
        :ok

      {:error, error_info} ->
        Logger.warn("Failed to remove peer from interface #{name}: #{error_info}")
        result
    end
  end

  def dump(name) do
    dump_fields = [
      :preshared_key,
      :endpoint,
      :allowed_ips,
      :persistent_keepalive,
      :latest_handshake,
      :rx_bytes,
      :tx_bytes
    ]

    result = wg_adapter().get_device(name)

    case result do
      %Wireguardex.Device{} ->
        Map.new(result.peers, fn peer ->
          info =
            Map.from_struct(peer.config)
            |> Map.merge(Map.from_struct(peer.stats))
            |> Enum.map(fn {k, v} ->
              case {k, v} do
                {:allowed_ips, []} -> {k, "(none)"}
                {:allowed_ips, ips} -> {k, Enum.join(ips, ",")}
                {:preshared_key, nil} -> {k, "(none)"}
                {:endpoint, nil} -> {k, "(none)"}
                {:last_handshake_time, t} -> {:latest_handshake, t}
                {:persistent_keepalive_interval, 0} -> {:persistent_keepalive, "off"}
                {:persistent_keepalive_interval, n} -> {:persistent_keepalive, n}
                _ -> {k, v}
              end
            end)
            |> Enum.into(%{})
            |> Map.take(dump_fields)

          {
            peer.config.public_key,
            info
          }
        end)

      {:error, error_info} ->
        Logger.warn("Failed to get interface #{name} stats: #{error_info}")
        result
    end
  end

  defp ip_cmds(name, ipv4_address, ipv6_address, mtu) do
    if !is_nil(ipv4_address) do
      exec!("ip address replace #{ipv4_address} dev #{name}")
    end

    if !is_nil(ipv6_address) do
      exec!("ip -6 address replace #{ipv6_address} dev #{name}")
    end

    if !is_nil(mtu) do
      exec!("ip link set mtu #{mtu} up dev #{name}")
    end
  end
end
