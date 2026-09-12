defmodule PortalAPI.Client.Views.ResourceTest do
  use ExUnit.Case, async: true

  alias Portal.Cache.Cacheable
  alias PortalAPI.Client.Views.Resource

  describe "render/3 for :device_pool on the v2 protocol" do
    test "renders a static_device_pool with id, name, devices, and filters; no sites or gateway_groups key" do
      id_bytes = Ecto.UUID.bingenerate()
      id_string = Ecto.UUID.cast!(id_bytes)
      device_id = Ecto.UUID.generate()

      ipv4 = %Postgrex.INET{address: {100, 65, 0, 1}, netmask: 32}
      ipv6 = %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}

      cacheable = %Cacheable.Resource{
        id: id_bytes,
        type: :device_pool,
        name: "Pool A",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.devices([device_id]),
        devices: [%{id: device_id, ipv4: ipv4, ipv6: ipv6}],
        filters: [%{protocol: :tcp, ports: ["443"]}]
      }

      rendered = Resource.render(cacheable, nil, 2)

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
      refute Map.has_key?(rendered, :device_membership_criteria)
      refute Map.has_key?(rendered, :ip_stack)
      refute Map.has_key?(rendered, :site)
    end

    test "JSON-encodes devices as objects with client_id, ipv4, ipv6 strings" do
      device_id = Ecto.UUID.generate()

      cacheable = %Cacheable.Resource{
        id: Ecto.UUID.bingenerate(),
        type: :device_pool,
        name: "Pool A",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.devices([device_id]),
        devices: [
          %{
            id: device_id,
            ipv4: %Postgrex.INET{address: {100, 65, 0, 1}, netmask: 32},
            ipv6: %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}
          }
        ],
        filters: []
      }

      json = JSON.encode!(Resource.render(cacheable, nil, 2))
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
        type: :device_pool,
        name: "Empty pool",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.devices([]),
        devices: nil,
        filters: []
      }

      assert %{devices: []} = Resource.render(cacheable, nil, 2)
    end

    test "renders an own-devices pool as a dynamic_device_pool with the device domain pattern" do
      id_bytes = Ecto.UUID.bingenerate()
      id_string = Ecto.UUID.cast!(id_bytes)

      cacheable = %Cacheable.Resource{
        id: id_bytes,
        type: :device_pool,
        name: "Your devices",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.own_devices(),
        devices: [],
        filters: [%{protocol: :tcp, ports: ["22"]}]
      }

      rendered = Resource.render(cacheable, nil, 2)

      assert rendered == %{
               id: id_string,
               type: :dynamic_device_pool,
               name: "Your devices",
               address: "*.firezone.network",
               filters: [%{protocol: :tcp, port_range_start: 22, port_range_end: 22}]
             }
    end
  end

  describe "render/3 for :device_pool on the v3 protocol" do
    test "renders id, type, name and filters; no devices, address, sites or gateway_groups" do
      id_bytes = Ecto.UUID.bingenerate()
      id_string = Ecto.UUID.cast!(id_bytes)

      cacheable = %Cacheable.Resource{
        id: id_bytes,
        type: :device_pool,
        name: "Laptops",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.own_devices(),
        devices: [
          %{
            id: Ecto.UUID.generate(),
            ipv4: %Postgrex.INET{address: {100, 65, 0, 1}, netmask: 32},
            ipv6: %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}
          }
        ],
        members: %{ipv4: "OjAAAAAAAAA=", ipv6: "OjAAAAAAAAA="},
        filters: [%{protocol: :tcp, ports: ["22"]}]
      }

      rendered = Resource.render(cacheable, nil, 3)

      assert rendered.id == id_string
      assert rendered.type == :device_pool
      assert rendered.name == "Laptops"
      assert rendered.members == %{ipv4: "OjAAAAAAAAA=", ipv6: "OjAAAAAAAAA="}
      assert [%{protocol: :tcp, port_range_start: 22, port_range_end: 22}] = rendered.filters

      refute Map.has_key?(rendered, :address)
      refute Map.has_key?(rendered, :device_membership_criteria)
      refute Map.has_key?(rendered, :gateway_groups)
      refute Map.has_key?(rendered, :sites)
      refute Map.has_key?(rendered, :devices)
      refute Map.has_key?(rendered, :site)
    end

    test "render_many/3 renders pools by protocol version" do
      cacheable = %Cacheable.Resource{
        id: Ecto.UUID.bingenerate(),
        type: :device_pool,
        name: "Pool A",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.devices([]),
        devices: [],
        filters: []
      }

      assert [%{type: :static_device_pool, devices: []}] = Resource.render_many([cacheable], nil, 2)
      assert [%{type: :device_pool} = rendered] = Resource.render_many([cacheable], nil, 3)
      refute Map.has_key?(rendered, :devices)
    end
  end
end
