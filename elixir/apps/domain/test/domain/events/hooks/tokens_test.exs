defmodule Domain.Events.Hooks.TokensTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Tokens

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(%{})
    end
  end

  describe "update/2" do
    test "returns :ok for email token updates" do
      assert :ok = on_update(%{"type" => "email"}, %{"type" => "email"})
    end

    test "soft-delete broadcasts deleted token" do
      account = Fixtures.Accounts.create_account()
      token = Fixtures.Tokens.create_token(account: account)
      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => token.type,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      assert :ok == on_update(old_data, data)
      assert_receive {:deleted, %Domain.Tokens.Token{} = deleted_token}
      assert deleted_token.id == old_data["id"]
      assert deleted_token.account_id == old_data["account_id"]
      assert deleted_token.type == old_data["type"]
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
      assert :ok = on_update(old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

    test "regular update returns :ok" do
      assert :ok = on_update(%{}, %{})
    end
  end

  describe "delete/1" do
    test "broadcasts deleted token" do
      account = Fixtures.Accounts.create_account()
      token = Fixtures.Tokens.create_token(account: account)
      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => token.type,
        "deleted_at" => nil
      }

      assert :ok == on_delete(old_data)

      assert_receive {:deleted, %Domain.Tokens.Token{} = deleted_token}
      assert deleted_token.id == old_data["id"]
      assert deleted_token.account_id == old_data["account_id"]
      assert deleted_token.type == old_data["type"]
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
      assert :ok = on_delete(old_data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end
end
