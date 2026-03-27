defmodule Portal.Changes.Hooks.ClientsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Devices
  import Portal.AccountFixtures
  import Portal.ClientFixtures
  import Portal.PolicyAuthorizationFixtures
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PubSub

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "update broadcasts updated client" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(client.account_id)

      old_data = %{"id" => client.id, "name" => "Old Name", "account_id" => client.account_id}
      data = %{"id" => client.id, "name" => "New Name", "account_id" => client.account_id}

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Device{} = old_client,
        struct: %Device{} = new_client,
        lsn: 0
      }

      assert old_client.name == "Old Name"
      assert new_client.name == "New Name"
      assert new_client.id == client.id
    end

    test "update unverifies client and deletes associated policy authorizations" do
      account = account_fixture()
      client = client_fixture(account: account, verified_at: DateTime.utc_now())
      :ok = PubSub.Changes.subscribe(client.account_id)

      old_data = %{
        "id" => client.id,
        "type" => "client",
        "verified_at" => "2023-10-01T00:00:00Z",
        "account_id" => client.account_id
      }

      data = %{
        "id" => client.id,
        "type" => "client",
        "verified_at" => nil,
        "account_id" => client.account_id
      }

      policy_authorization =
        policy_authorization_fixture(client: client, account: account)

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Device{},
        struct: %Device{} = new_client,
        lsn: 0
      }

      assert is_nil(new_client.verified_at)
      assert new_client.id == client.id
      refute Repo.get_by(Portal.PolicyAuthorization, id: policy_authorization.id)
    end
  end

  describe "delete/1" do
    test "broadcasts deleted client" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(client.account_id)

      old_data = %{"id" => client.id, "type" => "client", "account_id" => client.account_id}

      assert :ok == on_delete(0, old_data)
      assert_receive %Change{op: :delete, old_struct: %Device{} = deleted_client, lsn: 0}
      assert deleted_client.id == client.id
    end
  end
end
