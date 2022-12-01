defmodule FzHttpWeb.JSON.DeviceView do
  use FzHttpWeb, :view

  defimpl Jason.Encoder, for: Postgrex.INET do
    def encode(%Postgrex.INET{} = struct, opts) do
      Jason.Encode.string("#{struct}", opts)
    end
  end

  @keys_to_render ~w[
    id
    rx_bytes
    tx_bytes
    uuid
    name
    description
    public_key
    preshared_key
    use_site_allowed_ips
    use_site_dns
    use_site_endpoint
    use_site_mtu
    use_site_persistent_keepalive
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
    created_at
    user_id
  ]a

  def render("index.json", %{devices: devices}) do
    %{data: render_many(devices, __MODULE__, "device.json")}
  end

  def render("show.json", %{device: device}) do
    %{data: render_one(device, __MODULE__, "device.json")}
  end

  def render("device.json", %{device: device}) do
    Map.take(device, @keys_to_render)
  end
end
