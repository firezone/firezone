defmodule Portal.StaticDevicePoolMemberTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.GatewayFixtures
  import Portal.ResourceFixtures

  test "allows client devices as pool members" do
    account = account_fixture()
    actor = actor_fixture(account: account)
    client = client_fixture(account: account, actor: actor)
    resource = static_device_pool_resource_fixture(account: account)

    changeset =
      %Portal.StaticDevicePoolMember{}
      |> Ecto.Changeset.cast(
        %{
          account_id: account.id,
          resource_id: resource.id,
          device_id: client.id
        },
        [:account_id, :resource_id, :device_id]
      )
      |> Portal.StaticDevicePoolMember.changeset()

    assert {:ok, member} = Portal.Repo.insert(changeset)
    assert member.device_id == client.id
  end

  test "rejects gateway devices as pool members" do
    account = account_fixture()
    gateway = gateway_fixture(account: account)
    resource = static_device_pool_resource_fixture(account: account)

    changeset =
      %Portal.StaticDevicePoolMember{}
      |> Ecto.Changeset.cast(
        %{
          account_id: account.id,
          resource_id: resource.id,
          device_id: gateway.id
        },
        [:account_id, :resource_id, :device_id]
      )
      |> Portal.StaticDevicePoolMember.changeset()

    assert {:error, changeset} = Portal.Repo.insert(changeset)
    assert %{device_id: ["must reference a client device"]} = errors_on(changeset)
  end
end
