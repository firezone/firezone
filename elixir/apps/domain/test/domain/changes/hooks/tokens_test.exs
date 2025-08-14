defmodule Domain.Changes.Hooks.TokensTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.Tokens
  alias Domain.{Flows, PubSub}

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "returns :ok for email token updates" do
      assert :ok = on_update(0, %{"type" => "email"}, %{"type" => "email"})
    end

    test "soft-delete broadcasts disconnect" do
      account = Fixtures.Accounts.create_account()
      token = Fixtures.Tokens.create_token(account: account)

      :ok = PubSub.subscribe("sessions:#{token.id}")

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => token.type,
        "deleted_at" => nil
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == "sessions:#{token.id}"
    end

    test "soft-delete deletes flows" do
      account = Fixtures.Accounts.create_account()
      token = Fixtures.Tokens.create_token(account: account)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => token.type,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      assert flow = Fixtures.Flows.create_flow(account: account, token: token)
      assert flow.token_id == token.id
      assert :ok = on_update(0, old_data, data)
      refute Repo.get_by(Flows.Flow, id: flow.id)
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
        "type" => token.type,
        "deleted_at" => nil
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == "sessions:#{token.id}"
    end

    test "deletes flows" do
      account = Fixtures.Accounts.create_account()
      token = Fixtures.Tokens.create_token(account: account)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => token.type,
        "deleted_at" => nil
      }

      assert flow = Fixtures.Flows.create_flow(account: account, token: token)
      assert :ok = on_delete(0, old_data)
      refute Repo.get_by(Flows.Flow, id: flow.id)
    end
  end
end
