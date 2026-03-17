defmodule Portal.Changes.Hooks.TokensTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.TokenFixtures
  alias Portal.Changes.Hooks.ClientTokens
  alias Portal.Changes.Hooks.GatewayTokens
  alias Portal.PG

  describe "ClientTokens.on_insert/2" do
    test "returns :ok" do
      assert :ok == ClientTokens.on_insert(0, %{})
    end
  end

  describe "ClientTokens.on_update/3" do
    test "returns :ok" do
      assert :ok = ClientTokens.on_update(0, %{}, %{})
    end
  end

  describe "ClientTokens.on_delete/2" do
    test "sends :disconnect to registered token process" do
      account = account_fixture()
      token = client_token_fixture(account: account)

      PG.register(token.id)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "client"
      }

      assert :ok == ClientTokens.on_delete(0, old_data)
      assert_receive :disconnect
    end

    test "returns :ok when no process is registered for token" do
      account = account_fixture()
      token = client_token_fixture(account: account)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "client"
      }

      assert :ok == ClientTokens.on_delete(0, old_data)
    end
  end

  describe "GatewayTokens.on_insert/2" do
    test "returns :ok" do
      assert :ok == GatewayTokens.on_insert(0, %{})
    end
  end

  describe "GatewayTokens.on_update/3" do
    test "returns :ok" do
      assert :ok = GatewayTokens.on_update(0, %{}, %{})
    end
  end

  describe "GatewayTokens.on_delete/2" do
    test "sends :disconnect to registered token process" do
      account = account_fixture()
      token = gateway_token_fixture(account: account)

      PG.register(token.id)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "gateway"
      }

      assert :ok == GatewayTokens.on_delete(0, old_data)
      assert_receive :disconnect
    end

    test "returns :ok when no process is registered for token" do
      account = account_fixture()
      token = gateway_token_fixture(account: account)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "gateway"
      }

      assert :ok == GatewayTokens.on_delete(0, old_data)
    end
  end
end
