defmodule Portal.Changes.Hooks.StaticDevicePoolMembersTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.StaticDevicePoolMembers
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.ResourceFixtures
  import Portal.PolicyAuthorizationFixtures
  alias Portal.Changes.Change
  alias Portal.PolicyAuthorization
  alias Portal.PubSub
  alias Portal.StaticDevicePoolMember

  defp member_data(account, resource, device_id) do
    %{
      "id" => Ecto.UUID.generate(),
      "account_id" => account.id,
      "resource_id" => resource.id,
      "device_id" => device_id,
      "device_type" => "client"
    }
  end

  describe "insert/1" do
    test "broadcasts created member" do
      account = account_fixture()
      resource = resource_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :static_device_pool_members)

      data = member_data(account, resource, Ecto.UUID.generate())

      assert :ok == on_insert(0, data)
      assert_receive %Change{op: :insert, struct: %StaticDevicePoolMember{} = member, lsn: 0}
      assert member.resource_id == resource.id
    end
  end

  describe "delete/1" do
    test "broadcasts deleted member and revokes the member's responder authorizations" do
      account = account_fixture()
      resource = resource_fixture(account: account)
      responder = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :static_device_pool_members)

      authorization =
        policy_authorization_fixture(account: account, resource: resource, gateway: responder)

      data = member_data(account, resource, responder.id)

      assert :ok == on_delete(0, data)

      assert_receive %Change{op: :delete, old_struct: %StaticDevicePoolMember{}, lsn: 0}

      refute Repo.get_by(PolicyAuthorization, id: authorization.id)
    end

    test "does not revoke authorizations for other resources or devices" do
      account = account_fixture()
      resource = resource_fixture(account: account)
      other_resource = resource_fixture(account: account)
      responder = client_fixture(account: account)
      other_responder = client_fixture(account: account)

      authorization =
        policy_authorization_fixture(account: account, resource: resource, gateway: responder)

      other_pool_authorization =
        policy_authorization_fixture(
          account: account,
          resource: other_resource,
          gateway: responder
        )

      other_device_authorization =
        policy_authorization_fixture(
          account: account,
          resource: resource,
          gateway: other_responder
        )

      data = member_data(account, resource, responder.id)

      assert :ok == on_delete(0, data)

      refute Repo.get_by(PolicyAuthorization, id: authorization.id)
      assert Repo.get_by(PolicyAuthorization, id: other_pool_authorization.id)
      assert Repo.get_by(PolicyAuthorization, id: other_device_authorization.id)
    end
  end
end
