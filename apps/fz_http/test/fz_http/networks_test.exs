defmodule FzHttp.NetworksTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.Networks

  describe "list_networks/0" do
    setup :create_network

    test "shows all networks", %{network: network} do
      assert Networks.list_networks() == [network]
    end
  end

  describe "create_network/1" do
    @base_attrs %{
      private_key: "test",
      public_key: "test",
      interface_name: "wg-test",
      listen_port: 1
    }

    @tag attrs: Map.merge(@base_attrs, %{ipv4_address: "10.0.0.1", ipv4_network: "10.0.0.0/24"})
    test "creates a network with minimal attrs", %{attrs: attrs} do
      assert {:ok, network} = Networks.create_network(attrs)
      assert network.mtu == 1280
    end

    @tag attrs: Map.merge(@base_attrs, %{ipv4_address: "foobar", ipv4_network: "192.168.0.0/24"})
    test "prevents invalid IPv4 addresses", %{attrs: attrs} do
      assert {:error, changeset} = Networks.create_network(attrs)

      assert {"is invalid",
              [
                {:additional_info,
                 "Must specify a valid IPv4 address and network or IPv6 address and network."}
              ]} == changeset.errors[:ipv4_address]
    end

    @tag attrs: @base_attrs
    test "requires at least one of ipv4, ipv6 address", %{attrs: attrs} do
      assert {:error, changeset} = Networks.create_network(attrs)

      assert {"is invalid",
              [
                {:additional_info,
                 "Must specify a valid IPv4 address and network or IPv6 address and network."}
              ]} == changeset.errors[:ipv4_address]
    end

    @tag attrs: @base_attrs
    test "ensures ipv4_address is contained within ipv4_network", %{attrs: attrs} do
      assert {:ok, _network} =
               attrs
               |> Map.merge(%{ipv4_address: "10.0.0.1", ipv4_network: "10.0.0.0/24"})
               |> Networks.create_network()

      assert {:error, changeset} =
               attrs
               |> Map.merge(%{ipv4_address: "10.0.0.1", ipv4_network: "192.168.0.0/24"})
               |> Networks.create_network()

      assert changeset.errors[:ipv4_address] ==
               {"must be contained within the network 192.168.0.0/24", []}
    end

    @tag attrs: Map.merge(@base_attrs, %{ipv6_address: "::1", ipv6_network: "::/0"})
    test "ensures ipv6_address is contained within ipv6_network", %{attrs: attrs} do
      assert {:ok, _network} =
               attrs
               |> Map.merge(%{ipv6_address: "10.0.0.1", ipv6_network: "10.0.0.0/24"})
               |> Networks.create_network()

      assert {:error, changeset} =
               attrs
               |> Map.merge(%{ipv6_address: "10.0.0.1", ipv6_network: "192.168.0.0/24"})
               |> Networks.create_network()

      assert changeset.errors[:ipv6_address] ==
               {"must be contained within the network 192.168.0.0/24", []}
    end

    @tag attrs: @base_attrs
    test "prevents overlapping IPv4 networks", %{attrs: attrs} do
      assert {:ok, _network} =
               attrs
               |> Map.merge(%{ipv4_address: "10.0.0.1", ipv4_network: "10.0.0.0/24"})
               |> Networks.create_network()

      assert {:error, changeset} =
               attrs
               |> Map.merge(%{ipv4_address: "10.0.0.2", ipv4_network: "10.0.0.0/16"})
               |> Networks.create_network()

      assert changeset.errors[:ipv4_network] ==
               {"violates an exclusion constraint",
                [constraint: :exclusion, constraint_name: "networks_ipv4_network_excl"]}
    end

    @tag attrs: @base_attrs
    test "prevents overlapping IPv6 networks", %{attrs: attrs} do
      assert {:ok, _network} =
               attrs
               |> Map.merge(%{ipv6_address: "::1", ipv6_network: "::/64"})
               |> Networks.create_network()

      assert {:error, changeset} =
               attrs
               |> Map.merge(%{ipv6_address: "::1", ipv6_network: "::/0"})
               |> Networks.create_network()

      assert changeset.errors[:ipv6_network] ==
               {"violates an exclusion constraint",
                [constraint: :exclusion, constraint_name: "networks_ipv6_network_excl"]}
    end
  end

  describe "delete_network/1" do
    setup :create_network

    test "deletes the network", %{network: network} do
      assert {:ok, _network} = Networks.delete_network(network)
    end
  end
end
