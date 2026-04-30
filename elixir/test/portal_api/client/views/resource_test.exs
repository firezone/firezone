defmodule PortalAPI.Client.Views.ResourceTest do
  use ExUnit.Case, async: true

  alias Portal.Cache.Cacheable
  alias PortalAPI.Client.Views.Resource

  describe "render/1 for :static_device_pool" do
    test "renders id, type, name, devices, and filters; no sites or gateway_groups key" do
      id_bytes = Ecto.UUID.bingenerate()
      id_string = Ecto.UUID.cast!(id_bytes)
      device_id = Ecto.UUID.generate()

      ipv4 = %Postgrex.INET{address: {100, 65, 0, 1}, netmask: 32}
      ipv6 = %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}

      cacheable = %Cacheable.Resource{
        id: id_bytes,
        type: :static_device_pool,
        name: "Pool A",
        devices: [%{id: device_id, ipv4: ipv4, ipv6: ipv6}],
        filters: [%{protocol: :tcp, ports: ["443"]}]
      }

      rendered = Resource.render(cacheable)

      assert rendered.id == id_string
      assert rendered.type == :static_device_pool
      assert rendered.name == "Pool A"
      # The cache uses :id internally, but the wire shape uses :client_id.
      assert rendered.devices == [%{client_id: device_id, ipv4: ipv4, ipv6: ipv6}]
      assert [%{protocol: :tcp, port_range_start: 443, port_range_end: 443}] = rendered.filters

      # Pools are not tied to a site, so neither the legacy gateway_groups nor the new
      # sites key should appear in the payload.
      refute Map.has_key?(rendered, :gateway_groups)
      refute Map.has_key?(rendered, :sites)

      refute Map.has_key?(rendered, :address)
      refute Map.has_key?(rendered, :addresses)
      refute Map.has_key?(rendered, :address_description)
      refute Map.has_key?(rendered, :ip_stack)
      refute Map.has_key?(rendered, :site)
    end

    test "JSON-encodes devices as objects with client_id, ipv4, ipv6 strings" do
      device_id = Ecto.UUID.generate()

      cacheable = %Cacheable.Resource{
        id: Ecto.UUID.bingenerate(),
        type: :static_device_pool,
        name: "Pool A",
        devices: [
          %{
            id: device_id,
            ipv4: %Postgrex.INET{address: {100, 65, 0, 1}, netmask: 32},
            ipv6: %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}
          }
        ],
        filters: []
      }

      json = JSON.encode!(Resource.render(cacheable))
      decoded = JSON.decode!(json)

      assert [entry] = decoded["devices"]
      assert entry["client_id"] == device_id
      assert entry["ipv4"] == "100.65.0.1/32"
      assert entry["ipv6"] == "fd00::1/128"
      refute Map.has_key?(entry, "id")
    end

    test "renders empty devices list when nil" do
      cacheable = %Cacheable.Resource{
        id: Ecto.UUID.bingenerate(),
        type: :static_device_pool,
        name: "Empty pool",
        devices: nil,
        filters: []
      }

      assert %{devices: []} = Resource.render(cacheable)
    end
  end
end
