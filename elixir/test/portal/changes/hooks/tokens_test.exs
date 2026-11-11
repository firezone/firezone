defmodule Portal.Changes.Hooks.TokensTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.TokenFixtures
  alias Portal.Changes.Change
  alias Portal.Changes.Hooks.DeviceTokens
  alias Portal.PG

  describe "DeviceTokens.on_delete/2" do
    test "sends :disconnect to registered token process" do
      account = account_fixture()
      token = gateway_token_fixture(account: account)

      PG.register(token.id)

      assert :ok == DeviceTokens.on_delete(0, %{"id" => token.id, "account_id" => account.id})
      assert_receive :disconnect
    end

    test "broadcasts the deleted token" do
      account = account_fixture()
      token = client_token_fixture(account: account)
      token_id = token.id
      :ok = Portal.PubSub.Changes.subscribe(account.id, :client_tokens)

      assert :ok == DeviceTokens.on_delete(0, %{"id" => token.id, "account_id" => account.id})

      assert_receive %Change{op: :delete, old_struct: %Portal.DeviceToken{id: ^token_id}}
    end
  end

  describe "DeviceTokens.on_insert/2" do
    test "broadcasts the inserted token" do
      account = account_fixture()
      token = client_token_fixture(account: account)
      token_id = token.id
      :ok = Portal.PubSub.Changes.subscribe(account.id, :client_tokens)

      assert :ok == DeviceTokens.on_insert(0, %{"id" => token.id, "account_id" => account.id})

      assert_receive %Change{op: :insert, struct: %Portal.DeviceToken{id: ^token_id}}
    end
  end

  describe "DeviceTokens.on_update/3" do
    test "returns :ok" do
      assert :ok == DeviceTokens.on_update(0, %{}, %{})
    end
  end
end
