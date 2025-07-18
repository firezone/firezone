defmodule Domain.Events.Hooks.ClientsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Clients
  alias Domain.{Clients, PubSub}

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(%{})
    end
  end

  describe "update/2" do
    test "soft-delete broadcasts deleted client" do
      client = Fixtures.Clients.create_client()
      :ok = PubSub.Account.subscribe(client.account_id)

      old_data = %{"id" => client.id, "deleted_at" => nil, "account_id" => client.account_id}

      data = %{
        "id" => client.id,
        "deleted_at" => DateTime.utc_now(),
        "account_id" => client.account_id
      }

      assert :ok == on_update(old_data, data)
      assert_receive {:deleted, %Clients.Client{} = deleted_client}
      assert deleted_client.id == client.id
    end

    test "update broadcasts updated client" do
      account = Fixtures.Accounts.create_account()
      client = Fixtures.Clients.create_client(account: account)
      :ok = PubSub.Account.subscribe(client.account_id)

      old_data = %{"id" => client.id, "name" => "Old Name", "account_id" => client.account_id}
      data = %{"id" => client.id, "name" => "New Name", "account_id" => client.account_id}

      assert :ok == on_update(old_data, data)

      assert_receive {:updated, %Clients.Client{} = old_client, %Clients.Client{} = new_client}
      assert old_client.name == "Old Name"
      assert new_client.name == "New Name"
      assert new_client.id == client.id
    end

    test "update unverifies client and deletes associated flows" do
      account = Fixtures.Accounts.create_account()
      client = Fixtures.Clients.create_client(account: account, verified_at: DateTime.utc_now())
      :ok = PubSub.Account.subscribe(client.account_id)

      old_data = %{
        "id" => client.id,
        "verified_at" => "2023-10-01T00:00:00Z",
        "account_id" => client.account_id
      }

      data = %{"id" => client.id, "verified_at" => nil, "account_id" => client.account_id}

      assert flow = Fixtures.Flows.create_flow(client: client, account: account)
      assert :ok == on_update(old_data, data)
      assert_receive {:updated, %Clients.Client{}, %Clients.Client{} = new_client}
      assert is_nil(new_client.verified_at)
      assert new_client.id == client.id
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end

  describe "delete/1" do
    test "broadcasts deleted client" do
      account = Fixtures.Accounts.create_account()
      client = Fixtures.Clients.create_client(account: account)
      :ok = PubSub.Account.subscribe(client.account_id)

      old_data = %{"id" => client.id, "account_id" => client.account_id}

      assert :ok == on_delete(old_data)
      assert_receive {:deleted, %Clients.Client{} = deleted_client}
      assert deleted_client.id == client.id
    end

    test "deletes associated flows" do
      account = Fixtures.Accounts.create_account()
      client = Fixtures.Clients.create_client(account: account)

      old_data = %{"id" => client.id, "account_id" => client.account_id}

      assert flow = Fixtures.Flows.create_flow(client: client, account: account)
      assert :ok == on_delete(old_data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end
end
