defmodule FzVpn.Interface do
  @moduledoc """
  This module has functions to create interfaces, set configurations on them,
  and get peer info via [WireGuard](https://wireguard.com)
  """
  import FzVpn.Interface.WGAdapter

  alias Wireguardex.DeviceConfigBuilder
  alias Wireguardex.PeerConfigBuilder

  require Logger

  @doc """
  Set an interface by name with its peers. If the interface does not exist, it
  will be created.

  ## Options

  * `:private_key` - the interface's private key will be set
  * `:listen_port - the interface's listening port will be set

  If successful we return an :ok status. If interface fails to be set,
  `{:error, error_info}` will be logged and returned.
  """
  def set(name, peers, opts \\ []) do
    private_key = opts[:private_key]
    listen_port = opts[:listen_port]

    peer_configs =
      for {public_key, settings} <- peers do
        PeerConfigBuilder.peer_config()
        |> PeerConfigBuilder.public_key(public_key)
        |> PeerConfigBuilder.preshared_key(settings.preshared_key)
        |> PeerConfigBuilder.allowed_ips(String.split(settings.allowed_ips, ","))
      end

    result =
      DeviceConfigBuilder.device_config()
      |> DeviceConfigBuilder.private_key(private_key)
      |> DeviceConfigBuilder.listen_port(listen_port)
      |> DeviceConfigBuilder.peers(peer_configs)
      |> wg_adapter().set_device(name)

    case result do
      :ok ->
        :ok

      {:error, error_info} ->
        Logger.error("Failed to set interface #{name}: #{error_info}")
        result
    end
  end

  @doc """
  Get an interface by its name.

  If successful we return an `{:ok, Device}`. If the interface fails to be
  retrieved, return `{:error, error_info}`.
  """
  def get(name) do
    result = wg_adapter().get_device(name)

    case result do
      {:ok, device} ->
        {:ok, device}

      {:error, error_info} ->
        Logger.error("Failed to get interface #{name}: #{error_info}")
        result
    end
  end

  @doc """
  Get a list of interface names.

  If successful we return `{:ok, [Device]}. If getting the list fails, return
  '{:error, error_info}'.
  """
  def list_names do
    result = wg_adapter().list_devices()

    case result do
      {:ok, iface_names} ->
        {:ok, iface_names}

      {:error, error_info} ->
        Logger.error("Failed to get list of interface names: #{error_info}")
        result
    end
  end

  @doc """
  Delete an interface.

  If successful we return an :ok status. If interface fails to be deleted,
  `{:error, error_info}` will be logged and returned.
  """
  def delete(name) do
    result = wg_adapter().delete_device(name)

    case result do
      :ok ->
        :ok

      {:error, error_info} ->
        Logger.error("Failed to delete interface #{name}: #{error_info}")
        result
    end
  end

  @doc """
  Remove a peer from an interface.

  If successful we return an :ok status. If the peer fails to be removed from
  the interface, `{:error, error_info}` will be logged and returned.
  """
  def remove_peer(name, public_key) do
    result = wg_adapter().remove_peer(name, public_key)

    case result do
      :ok ->
        :ok

      {:error, error_info} ->
        Logger.error("Failed to remove peer from interface #{name}: #{error_info}")
        result
    end
  end

  @doc """
  Return a map of information on all the current peers of the interface.

  If successful we return the map of peer information. If the device fails to be
  retrieved for info, `{:error, error_info}` will be logged and returned.
  """
  def dump(name) do
    result = get(name)

    case result do
      {:ok, device} ->
        peers_to_dump_map(device.peers)

      {:error, error_info} ->
        Logger.error("Failed to get interface #{name} stats: #{error_info}")
        result
    end
  end

  defp peers_to_dump_map(peers) do
    Map.new(peers, fn peer ->
      dump =
        Map.from_struct(peer.config)
        |> Map.merge(Map.from_struct(peer.stats))
        |> Enum.map(&dump_field/1)
        |> Map.new()
        # dump these fields from the peer info
        |> Map.take([
          :preshared_key,
          :endpoint,
          :allowed_ips,
          :persistent_keepalive,
          :latest_handshake,
          :rx_bytes,
          :tx_bytes
        ])

      {
        peer.config.public_key,
        dump
      }
    end)
  end

  defp dump_field({field, value}) do
    case {field, value} do
      {:allowed_ips, allowed_ips} ->
        {:allowed_ips, allowed_ips_to_str(allowed_ips)}

      {:persistent_keepalive_interval, n} ->
        {:persistent_keepalive, persistent_keepalive_to_str(n)}

      {:endpoint, nil} ->
        {:endpoint, "(none)"}

      {:last_handshake_time, t} ->
        {:latest_handshake, latest_handshake_to_str(t)}

      {:preshared_key, nil} ->
        {:preshared_key, "(none)"}

      _ ->
        {field, to_string(value)}
    end
  end

  defp allowed_ips_to_str([]), do: "(none)"
  defp allowed_ips_to_str(allowed_ips), do: Enum.join(allowed_ips, ",")

  defp latest_handshake_to_str(t) when is_nil(t), do: "0"
  defp latest_handshake_to_str(t), do: to_string(t)

  defp persistent_keepalive_to_str(n) when is_nil(n) or n == 0, do: "off"
  defp persistent_keepalive_to_str(n), do: to_string(n)
end
