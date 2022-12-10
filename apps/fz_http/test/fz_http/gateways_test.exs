defmodule FzHttp.GatewaysTest do
  use FzHttp.DataCase, async: true

  describe "gateways" do
    alias FzHttp.{Gateways, Gateways.Gateway}

    import FzHttp.GatewaysFixtures

    test "list_gateways/0 returns all gateways" do
      gateway = gateway()
      assert Gateways.list_gateways() == [gateway]
    end

    test "get_gateway!/0 returns default named gateway" do
      gateway = gateway()
      assert Gateways.get_gateway!() == gateway
      assert "default" == gateway.name
    end

    test "get_gateway!/1 returns gateway by id" do
      gateway = gateway()
      assert Gateways.get_gateway!(id: gateway.id) == gateway
    end

    test "get_gateway!/1 returns gateway by name" do
      gateway = gateway(%{name: "gateway"})
      assert Gateways.get_gateway!(name: "gateway") == gateway
    end

    test "create_gateway/1 with unique name creates a gateway" do
      unique_name = %{
        name: "gateway",
        registration_token: "test_token",
        registration_token_created_at: DateTime.utc_now()
      }

      assert {:ok, %Gateway{} = gateway} = Gateways.create_gateway(unique_name)
      assert gateway.name == "gateway"
    end

    test "create_gateway/1 with duplicate name returns an error changeset" do
      _ = gateway(%{name: "gateway"})

      duplicate_name = %{
        name: "gateway",
        registration_token: "test_token",
        registration_token_created_at: DateTime.utc_now()
      }

      assert {:error, %Ecto.Changeset{}} = Gateways.create_gateway(duplicate_name)
    end
  end
end
