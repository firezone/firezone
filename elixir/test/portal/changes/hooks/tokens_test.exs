defmodule Portal.Changes.Hooks.TokensTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.TokenFixtures
  alias Portal.Changes.Hooks.ClientTokens
  alias Portal.PubSub

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
    test "broadcasts disconnect message on socket topic" do
      account = account_fixture()
      token = client_token_fixture(account: account)

      topic = Portal.Sockets.socket_id(token.id)
      :ok = PubSub.subscribe(topic)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "client"
      }

      assert :ok == ClientTokens.on_delete(0, old_data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "disconnect"
      }
    end
  end
end
