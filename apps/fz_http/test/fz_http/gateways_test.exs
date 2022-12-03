defmodule FzHttp.GatewaysTest do
  use FzHttp.DataCase, async: true

  describe "gateways" do
    alias EctoNetwork.INET
    alias FzHttp.{Gateways, Gateways.Gateway}

    import FzHttp.GatewaysFixtures

    test "get_gateway!/1 returns gateway by id" do
      gateway = gateway()
      assert gateway == Gateways.get_gateway!(id: gateway.id)
    end

    test "get_gateway!/1 returns gateway by name" do
      gateway = gateway()
      assert gateway == Gateways.get_gateway!(name: gateway.name)
    end

    test "create_gateway/1 with unique name creates a gateway" do
      attrs = gateway_gen_attrs()
      name = attrs[:name]
      pub_key = attrs[:public_key]

      assert {:ok, %Gateway{name: ^name, public_key: ^pub_key}} = Gateways.create_gateway(attrs)
    end

    test "create_gateway/1 with duplicate name returns an error" do
      _ = gateway(%{name: "gateway"})

      dupe_name =
        gateway_gen_attrs()
        |> Map.merge(%{name: "gateway"})

      assert {:error, %Ecto.Changeset{errors: errors}} = Gateways.create_gateway(dupe_name)
      assert [name: {"has already been taken", _}] = errors
    end

    test "create_gateway/1 with unique ipv4 creates a gateway" do
      unique_ipv4 =
        gateway_gen_attrs()
        |> Map.merge(%{ipv4_address: "10.10.10.1"})

      assert {:ok, %Gateway{ipv4_address: address}} = Gateways.create_gateway(unique_ipv4)
      assert INET.decode(address) == "10.10.10.1"
    end

    test "create_gateway/1 with duplicate ipv4 creates a gateway" do
      _ = gateway(%{ipv4_address: "10.10.10.1"})

      duplicate_ipv4 =
        gateway_gen_attrs()
        |> Map.merge(%{ipv4_address: "10.10.10.1"})

      assert {:error, %Ecto.Changeset{errors: errors}} = Gateways.create_gateway(duplicate_ipv4)
      assert [ipv4_address: {"has already been taken", _}] = errors
    end

    test "create_gateway/1 with unique ipv6 creates a gateway" do
      unique_ipv6 =
        gateway_gen_attrs()
        |> Map.merge(%{ipv6_address: "2a03:b0c0:2:f0::2c:2002"})

      assert {:ok, %Gateway{ipv6_address: address}} = Gateways.create_gateway(unique_ipv6)
      assert INET.decode(address) == "2a03:b0c0:2:f0::2c:2002"
    end

    test "create_gateway/1 with duplicate ipv6 creates a gateway" do
      _ = gateway(%{ipv6_address: "2a03:b0c0:2:f0::2c:2002"})

      duplicate_ipv6 =
        gateway_gen_attrs()
        |> Map.merge(%{ipv6_address: "2a03:b0c0:2:f0::2c:2002"})

      assert {:error, %Ecto.Changeset{errors: errors}} = Gateways.create_gateway(duplicate_ipv6)
      assert [ipv6_address: {"has already been taken", _}] = errors
    end
  end
end
