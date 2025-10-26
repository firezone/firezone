defmodule Domain.Changes.Hooks.TokensTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.Tokens
  alias Domain.PubSub

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "returns :ok for email token updates" do
      assert :ok = on_update(0, %{"type" => "email"}, %{"type" => "email"})
    end

    test "regular update returns :ok" do
      assert :ok = on_update(0, %{}, %{})
    end
  end

  describe "delete/1" do
    test "broadcasts disconnect message" do
      account = Fixtures.Accounts.create_account()
      token = Fixtures.Tokens.create_token(account: account)

      :ok = PubSub.subscribe("sessions:#{token.id}")

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => token.type
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == "sessions:#{token.id}"
    end
  end
end
