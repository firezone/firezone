defmodule Portal.RoutingTest do
  use ExUnit.Case, async: true

  alias Portal.Cache.Cacheable
  alias Portal.Device
  alias Portal.Routing

  describe "compatible?/3" do
    test "an initiator without a version is compatible with every device" do
      assert Routing.compatible?(device("1.0.0"), cidr_resource(), nil)
    end

    test "an initiator whose version does not parse is compatible with nothing" do
      refute Routing.compatible?(device("1.5.0"), cidr_resource(), "not-a-version")
    end

    test "a device without a version is compatible with nothing" do
      refute Routing.compatible?(device(nil), cidr_resource(), "1.5.0")
    end

    test "a device within one minor version in either direction is compatible" do
      assert Routing.compatible?(device("1.4.9"), cidr_resource(), "1.5.0")
      assert Routing.compatible?(device("1.5.3"), cidr_resource(), "1.5.0")
      assert Routing.compatible?(device("1.6.0"), cidr_resource(), "1.5.0")
    end

    test "a device two minor versions away is not compatible" do
      refute Routing.compatible?(device("1.3.9"), cidr_resource(), "1.5.0")
      refute Routing.compatible?(device("1.7.0"), cidr_resource(), "1.5.0")
    end

    test "a device that does not understand the resource type is not compatible" do
      refute Routing.compatible?(device("1.2.5"), internet_resource(), "1.2.5")
      assert Routing.compatible?(device("1.3.0"), internet_resource(), "1.3.0")
    end
  end

  describe "select_receiver/3" do
    test "returns nil with no candidates" do
      assert Routing.select_receiver([], {nil, nil}, []) == nil
    end

    test "prefers a candidate the initiator is already connected to" do
      preferred = device("1.5.0", "11111111-1111-1111-1111-111111111111")
      other = device("1.5.0", "22222222-2222-2222-2222-222222222222")

      assert Routing.select_receiver([other, preferred], {nil, nil}, [preferred.id]) == preferred
    end

    test "falls back to the candidates when none is preferred" do
      only = device("1.5.0", "11111111-1111-1111-1111-111111111111")

      assert Routing.select_receiver([only], {nil, nil}, ["22222222-2222-2222-2222-222222222222"]) ==
               only
    end
  end

  defp device(version, id \\ Ecto.UUID.generate()) do
    %Device{id: id, type: :gateway, last_seen_version: version}
  end

  defp cidr_resource do
    %Cacheable.Resource{type: :cidr, address: "10.0.0.0/24", filters: []}
  end

  defp internet_resource do
    %Cacheable.Resource{type: :internet, filters: []}
  end
end
