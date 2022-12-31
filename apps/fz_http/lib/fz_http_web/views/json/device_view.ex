defmodule FzHttpWeb.JSON.DeviceView do
  @moduledoc """
  Handles JSON rendering of Device records.
  """
  use FzHttpWeb, :view

  alias FzHttp.Devices

  def render("index.json", %{devices: devices}) do
    %{data: render_many(devices, __MODULE__, "device.json")}
  end

  def render("show.json", %{device: device}) do
    %{data: render_one(device, __MODULE__, "device.json")}
  end

  @keys_to_render ~w[
    id
    rx_bytes
    tx_bytes
    name
    description
    public_key
    preshared_key
    use_default_allowed_ips
    use_default_dns
    use_default_endpoint
    use_default_mtu
    use_default_persistent_keepalive
    endpoint
    mtu
    persistent_keepalive
    allowed_ips
    dns
    remote_ip
    ipv4
    ipv6
    latest_handshake
    updated_at
    inserted_at
    user_id
  ]a
  def render("device.json", %{device: device}) do
    Map.merge(
      Map.take(device, @keys_to_render),
      %{
        server_public_key: Application.get_env(:fz_vpn, :wireguard_public_key),
        endpoint: Devices.config(device, :endpoint),
        allowed_ips: Devices.config(device, :allowed_ips),
        dns: Devices.config(device, :dns),
        persistent_keepalive: Devices.config(device, :persistent_keepalive),
        mtu: Devices.config(device, :mtu)
      }
    )
  end
end
