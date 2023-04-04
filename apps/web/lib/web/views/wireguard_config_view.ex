defmodule Web.WireguardConfigView do
  use Web, :view
  alias Domain.Config
  alias Domain.Devices
  require Logger

  def render("base64_device.conf", %{device: device}) do
    render("device.conf", %{device: device})
    |> Base.encode64()
  end

  def render("device.conf", %{device: device}) do
    server_public_key = Application.get_env(:domain, :wireguard_public_key)
    defaults = Devices.defaults()

    if is_nil(server_public_key) do
      Logger.error(
        "No server public key found! This will break device config generation. Is fz_vpn alive?"
      )
    end

    """
    [Interface]
    PrivateKey = REPLACE_ME
    Address = #{Devices.inet(device)}
    #{mtu_config(device, defaults)}
    #{dns_config(device, defaults)}

    [Peer]
    #{psk_config(device)}
    PublicKey = #{server_public_key}
    #{allowed_ips_config(device, defaults)}
    #{endpoint_config(device, defaults)}
    #{persistent_keepalive_config(device, defaults)}
    """
  end

  defp psk_config(device) do
    if device.preshared_key do
      "PresharedKey = #{device.preshared_key}"
    else
      ""
    end
  end

  defp mtu_config(device, defaults) do
    m = Devices.get_mtu(device, defaults)

    if field_empty?(m) do
      ""
    else
      "MTU = #{m}"
    end
  end

  defp allowed_ips_config(device, defaults) do
    allowed_ips = Devices.get_allowed_ips(device, defaults)

    if field_empty?(allowed_ips) do
      ""
    else
      "AllowedIPs = #{Enum.join(allowed_ips, ",")}"
    end
  end

  defp persistent_keepalive_config(device, defaults) do
    pk = Devices.get_persistent_keepalive(device, defaults)

    if field_empty?(pk) do
      ""
    else
      "PersistentKeepalive = #{pk}"
    end
  end

  defp dns_config(device, defaults) when is_struct(device) do
    dns = Devices.get_dns(device, defaults)

    if field_empty?(dns) do
      ""
    else
      "DNS = #{Enum.join(dns, ",")}"
    end
  end

  defp endpoint_config(device, defaults) do
    ep = Devices.get_endpoint(device, defaults)

    if field_empty?(ep) do
      ""
    else
      "Endpoint = #{maybe_add_port(ep)}"
    end
  end

  defp maybe_add_port(%Domain.Types.IPPort{port: nil} = ip_port) do
    wireguard_port = Config.fetch_env!(:domain, :wireguard_port)
    Domain.Types.IPPort.to_string(%{ip_port | port: wireguard_port})
  end

  defp maybe_add_port(%Domain.Types.IPPort{} = ip_port) do
    Domain.Types.IPPort.to_string(ip_port)
  end

  # Finds a port in IPv6-formatted address, e.g. [2001::1]:51820
  @capture_port ~r/\[.*]:(?<port>[\d]+)/
  defp maybe_add_port(endpoint) do
    wireguard_port = Domain.Config.fetch_env!(:domain, :wireguard_port)
    colon_count = endpoint |> String.graphemes() |> Enum.count(&(&1 == ":"))

    if colon_count == 1 or !is_nil(Regex.named_captures(@capture_port, endpoint)) do
      endpoint
    else
      # No port found
      "#{endpoint}:#{wireguard_port}"
    end
  end

  defp field_empty?(nil), do: true
  defp field_empty?(0), do: true
  defp field_empty?([]), do: true

  defp field_empty?(field) when is_binary(field) do
    len =
      field
      |> String.trim()
      |> String.length()

    len == 0
  end

  defp field_empty?(_), do: false
end
