defmodule FzHttpWeb.JSON.DeviceView do
  @moduledoc """
  Handles JSON rendering of Device records.
  """
  use FzHttpWeb, :view

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
    key_regenerated_at
    updated_at
    inserted_at
    user_id
  ]a
  def render("device.json", %{device: device}) do
    Map.take(device, @keys_to_render)
  end
end
