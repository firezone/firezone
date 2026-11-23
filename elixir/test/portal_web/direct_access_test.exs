defmodule PortalWeb.DirectAccessTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.ResourceFixtures
  import Portal.SubjectFixtures

  alias PortalWeb.DirectAccess

  setup do
    account = account_fixture()
    admin = admin_actor_fixture(account: account)
    subject = subject_fixture(account: account, actor: admin)
    resource = resource_fixture(account: account, name: "Prod database")

    %{account: account, subject: subject, resource: resource}
  end

  describe "grant/3" do
    test "makes one group and one policy for the resource", %{
      account: account,
      subject: subject,
      resource: resource
    } do
      alice = actor_fixture(account: account, name: "Alice")
      bob = actor_fixture(account: account, name: "Bob")

      assert {:ok, group} = DirectAccess.grant(resource, [alice.id], subject)
      assert DirectAccess.direct_group?(group)
      assert {:ok, ^group} = DirectAccess.grant(resource, [bob.id, alice.id], subject)

      assert [policy] = Repo.all(from p in Portal.Policy, where: p.resource_id == ^resource.id)
      assert policy.group_id == group.id

      assert Enum.map(DirectAccess.list_people(resource, subject), & &1.name) == ["Alice", "Bob"]
    end

    test "does not reuse a group an admin made with the same name", %{
      account: account,
      subject: subject,
      resource: resource
    } do
      group_fixture(account: account, name: "Direct access: Prod database")
      alice = actor_fixture(account: account)

      assert {:ok, group} = DirectAccess.grant(resource, [alice.id], subject)
      assert group.resource_id == resource.id
    end

    test "rejects actors from another account", %{subject: subject, resource: resource} do
      stranger = actor_fixture(account: account_fixture())

      assert {:error, _reason} = DirectAccess.grant(resource, [stranger.id], subject)
      assert DirectAccess.get_group(resource, subject) == nil
    end
  end

  describe "revoke/3" do
    test "deletes the group with its last member", %{
      account: account,
      subject: subject,
      resource: resource
    } do
      alice = actor_fixture(account: account)
      bob = actor_fixture(account: account)
      {:ok, _group} = DirectAccess.grant(resource, [alice.id, bob.id], subject)

      assert :ok = DirectAccess.revoke(resource, alice.id, subject)
      assert [%{id: bob_id}] = DirectAccess.list_people(resource, subject)
      assert bob_id == bob.id

      assert :ok = DirectAccess.revoke(resource, bob.id, subject)
      assert DirectAccess.get_group(resource, subject) == nil
      assert Repo.all(from p in Portal.Policy, where: p.resource_id == ^resource.id) == []
    end
  end

  test "deleting the resource deletes its direct-access group", %{
    account: account,
    subject: subject,
    resource: resource
  } do
    alice = actor_fixture(account: account)
    {:ok, group} = DirectAccess.grant(resource, [alice.id], subject)

    Repo.delete!(resource)

    refute Repo.get_by(Portal.Group, id: group.id)
  end
end
