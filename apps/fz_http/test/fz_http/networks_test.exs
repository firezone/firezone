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
    @tag attrs: %{
           private_key: "test",
           public_key: "test",
           interface_name: "wg-test",
           listen_port: 1
         }
    test "creates a network with minimal attrs", %{attrs: attrs} do
      assert {:ok, network} = Networks.create_network(attrs)
      assert network.mtu == 1280
    end
  end

  describe "delete_network/1" do
    setup :create_network

    test "deletes the network", %{network: network} do
      assert {:ok, _network} = Networks.delete_network(network)
    end
  end
end
