defmodule Domain.ResourcesTest do
  use Domain.DataCase, async: true
  import Domain.Resources
  alias Domain.Resources
  alias Domain.Actors

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    }
  end

  describe "fetch_resource_by_id/3" do
    test "returns error when resource does not exist", %{subject: subject} do
      assert fetch_resource_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_resource_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns resource for account admin", %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)

      assert {:ok, fetched_resource} = fetch_resource_by_id(resource.id, subject)
      assert fetched_resource.id == resource.id
    end

    test "returns authorized resource for account user", %{
      account: account
    } do
      actor_group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      resource = Fixtures.Resources.create_resource(account: account)

      assert fetch_resource_by_id(resource.id, subject) == {:error, :not_found}

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      assert {:ok, fetched_resource} = fetch_resource_by_id(resource.id, subject)
      assert fetched_resource.id == resource.id
      assert Enum.map(fetched_resource.authorized_by_policies, & &1.id) == [policy.id]
    end

    test "returns deleted resources", %{account: account, subject: subject} do
      {:ok, resource} =
        Fixtures.Resources.create_resource(account: account)
        |> delete_resource(subject)

      assert {:ok, _resource} = fetch_resource_by_id(resource.id, subject)
    end

    test "does not return resources in other accounts", %{subject: subject} do
      resource = Fixtures.Resources.create_resource()
      assert fetch_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "returns error when subject has no permission to view resources", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_resource_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Resources.Authorizer.manage_resources_permission(),
                      Resources.Authorizer.view_available_resources_permission()
                    ]}
                 ]}}
    end

    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:ok, resource} = fetch_resource_by_id(resource.id, subject, preload: :connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert length(resource.connections) == 1
    end
  end

  describe "fetch_resource_by_id_or_persistent_id/3" do
    test "returns error when resource does not exist", %{subject: subject} do
      assert fetch_resource_by_id_or_persistent_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_resource_by_id_or_persistent_id("foo", subject) == {:error, :not_found}
    end

    test "returns resource for account admin", %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)

      assert {:ok, fetched_resource} = fetch_resource_by_id_or_persistent_id(resource.id, subject)
      assert fetched_resource.id == resource.id

      assert {:ok, fetched_resource} =
               fetch_resource_by_id_or_persistent_id(resource.persistent_id, subject)

      assert fetched_resource.id == resource.id
    end

    test "returns authorized resource for account user", %{
      account: account
    } do
      actor_group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      resource = Fixtures.Resources.create_resource(account: account)

      assert fetch_resource_by_id_or_persistent_id(resource.id, subject) == {:error, :not_found}

      assert fetch_resource_by_id_or_persistent_id(resource.persistent_id, subject) ==
               {:error, :not_found}

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      assert {:ok, fetched_resource} = fetch_resource_by_id_or_persistent_id(resource.id, subject)
      assert fetched_resource.id == resource.id
      assert Enum.map(fetched_resource.authorized_by_policies, & &1.id) == [policy.id]

      assert {:ok, fetched_resource} =
               fetch_resource_by_id_or_persistent_id(resource.persistent_id, subject)

      assert fetched_resource.id == resource.id
      assert Enum.map(fetched_resource.authorized_by_policies, & &1.id) == [policy.id]
    end

    test "returns deleted resources", %{account: account, subject: subject} do
      {:ok, resource} =
        Fixtures.Resources.create_resource(account: account)
        |> delete_resource(subject)

      assert {:ok, _resource} = fetch_resource_by_id_or_persistent_id(resource.id, subject)

      assert {:ok, _resource} =
               fetch_resource_by_id_or_persistent_id(resource.persistent_id, subject)
    end

    test "does not return resources in other accounts", %{subject: subject} do
      resource = Fixtures.Resources.create_resource()
      assert fetch_resource_by_id_or_persistent_id(resource.id, subject) == {:error, :not_found}

      assert fetch_resource_by_id_or_persistent_id(resource.persistent_id, subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view resources", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_resource_by_id_or_persistent_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Resources.Authorizer.manage_resources_permission(),
                      Resources.Authorizer.view_available_resources_permission()
                    ]}
                 ]}}
    end

    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:ok, resource} =
               fetch_resource_by_id_or_persistent_id(resource.id, subject, preload: :connections)

      assert Ecto.assoc_loaded?(resource.connections)
      assert length(resource.connections) == 1

      assert {:ok, resource} =
               fetch_resource_by_id_or_persistent_id(resource.persistent_id, subject,
                 preload: :connections
               )

      assert Ecto.assoc_loaded?(resource.connections)
      assert length(resource.connections) == 1
    end
  end

  describe "fetch_and_authorize_resource_by_id/3" do
    test "returns error when resource does not exist", %{subject: subject} do
      assert fetch_and_authorize_resource_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_and_authorize_resource_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns authorized resource for account admin", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      assert {:ok, fetched_resource} = fetch_and_authorize_resource_by_id(resource.id, subject)
      assert fetched_resource.id == resource.id
      assert Enum.map(fetched_resource.authorized_by_policies, & &1.id) == [policy.id]
    end

    test "returns authorized resource for account user", %{
      account: account
    } do
      actor_group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      resource = Fixtures.Resources.create_resource(account: account)

      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      assert {:ok, fetched_resource} = fetch_and_authorize_resource_by_id(resource.id, subject)
      assert fetched_resource.id == resource.id
      assert Enum.map(fetched_resource.authorized_by_policies, & &1.id) == [policy.id]
    end

    test "returns authorized resource using one of multiple policies for account user", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      resource = Fixtures.Resources.create_resource(account: account)

      actor_group1 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group1)

      policy1 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group1,
          resource: resource
        )

      actor_group2 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group2)

      policy2 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group2,
          resource: resource
        )

      assert {:ok, fetched_resource} = fetch_and_authorize_resource_by_id(resource.id, subject)
      assert fetched_resource.id == resource.id

      authorized_by_policy_ids = Enum.map(fetched_resource.authorized_by_policies, & &1.id)
      policy_ids = [policy1.id, policy2.id]
      assert Enum.sort(authorized_by_policy_ids) == Enum.sort(policy_ids)
    end

    test "does not return deleted resources", %{account: account, actor: actor, subject: subject} do
      {:ok, resource} =
        Fixtures.Resources.create_resource(account: account)
        |> delete_resource(subject)

      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "does not authorize using deleted policies", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )
      |> Fixtures.Policies.delete_policy()

      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "does not authorize using deleted group membership", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      # memberships are not soft deleted
      # Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "does not authorize using disabled policies", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      {:ok, _policy} = Domain.Policies.disable_policy(policy, subject)

      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "does not return resources in other accounts", %{subject: subject} do
      resource = Fixtures.Resources.create_resource()
      assert fetch_and_authorize_resource_by_id(resource.id, subject) == {:error, :not_found}
    end

    test "returns error when subject has no permission to view resources", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_and_authorize_resource_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.view_available_resources_permission()]}}
    end

    test "associations are preloaded when opts given", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      assert {:ok, resource} =
               fetch_and_authorize_resource_by_id(resource.id, subject, preload: :connections)

      assert Ecto.assoc_loaded?(resource.connections)
      assert length(resource.connections) == 1
    end
  end

  describe "all_authorized_resources/1" do
    test "returns empty list when there are no resources", %{subject: subject} do
      assert {:ok, []} = all_authorized_resources(subject)
    end

    test "returns empty list when there are no authorized resources", %{
      account: account,
      subject: subject
    } do
      Fixtures.Resources.create_resource(account: account)
      assert {:ok, []} = all_authorized_resources(subject)
    end

    test "does not list deleted resources", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      resource |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

      assert {:ok, []} = all_authorized_resources(subject)
    end

    test "does not list resources authorized by disabled policy", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      {:ok, _policy} = Domain.Policies.disable_policy(policy, subject)

      assert {:ok, []} = all_authorized_resources(subject)
    end

    test "returns authorized resources for account user subject", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      gateway_group1 = Fixtures.Gateways.create_group(account: account)
      gateway_group2 = Fixtures.Gateways.create_group(account: account)

      resource1 =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group1.id}]
        )

      resource2 =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group2.id}]
        )

      Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource()

      assert {:ok, []} = all_authorized_resources(subject)

      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource1
        )

      assert {:ok, resources} = all_authorized_resources(subject)
      assert length(resources) == 1
      assert Enum.map(hd(resources).authorized_by_policies, & &1.id) == [policy.id]

      policy2 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource2
        )

      assert {:ok, resources2} = all_authorized_resources(subject)
      assert length(resources2) == 2

      assert hd(hd(resources2 -- resources).authorized_by_policies).id == policy2.id
    end

    test "returns authorized resources for account admin subject", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      gateway_group1 = Fixtures.Gateways.create_group(account: account)
      gateway_group2 = Fixtures.Gateways.create_group(account: account)

      resource1 =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group1.id}]
        )

      resource2 =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group2.id}]
        )

      Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource()

      assert {:ok, []} = all_authorized_resources(subject)

      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource1
        )

      assert {:ok, resources} = all_authorized_resources(subject)
      assert length(resources) == 1
      assert Enum.map(hd(resources).authorized_by_policies, & &1.id) == [policy.id]

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource2
      )

      assert {:ok, resources} = all_authorized_resources(subject)
      assert length(resources) == 2
    end

    test "does not authorize resources for deleted gateway groups", %{
      account: account
    } do
      actor_group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      assert {:ok, [_resource]} = all_authorized_resources(subject)

      Fixtures.Gateways.delete_group(gateway_group)
      assert {:ok, []} = all_authorized_resources(subject)
    end

    test "returns error when subject has no permission to manage resources", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert all_authorized_resources(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.view_available_resources_permission()]}}
    end
  end

  describe "list_resources/2" do
    test "returns empty list when there are no resources", %{subject: subject} do
      assert {:ok, [], _metadata} = list_resources(subject)
    end

    test "does not list resources from other accounts", %{
      subject: subject
    } do
      Fixtures.Resources.create_resource()
      assert {:ok, [], _metadata} = list_resources(subject)
    end

    test "does not list deleted resources", %{
      account: account,
      subject: subject
    } do
      Fixtures.Resources.create_resource(account: account)
      |> delete_resource(subject)

      assert {:ok, [], _metadata} = list_resources(subject)
    end

    test "returns all resources for account admin subject", %{
      account: account,
      subject: subject
    } do
      Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource()

      assert {:ok, resources, _metadata} = list_resources(subject)
      assert length(resources) == 2
    end

    test "returns error when subject has no permission to manage resources", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_resources(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   Resources.Authorizer.manage_resources_permission()
                 ]}}
    end
  end

  describe "count_resources_for_gateway/2" do
    test "returns zero when there are no resources associated to gateway", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      assert count_resources_for_gateway(gateway, subject) == {:ok, 0}
    end

    test "does not count resources that are not associated to the gateway", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

      Fixtures.Resources.create_resource(account: account)

      assert count_resources_for_gateway(gateway, subject) == {:ok, 1}
    end

    test "does not count deleted resources associated to gateway", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )
      |> delete_resource(subject)

      assert count_resources_for_gateway(gateway, subject) == {:ok, 1}
    end

    test "returns error when subject has no permission to manage resources",
         %{
           account: account,
           subject: subject
         } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

      subject = Fixtures.Auth.remove_permissions(subject)

      assert count_resources_for_gateway(gateway, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Resources.Authorizer.manage_resources_permission(),
                      Resources.Authorizer.view_available_resources_permission()
                    ]}
                 ]}}
    end
  end

  describe "list_resources_for_gateway/2" do
    test "returns empty list when there are no resources associated to gateway", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      assert list_resources_for_gateway(gateway, subject) == {:ok, []}
    end

    test "does not list resources that are not associated to the gateway", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      Fixtures.Resources.create_resource()

      assert list_resources_for_gateway(gateway, subject) == {:ok, []}
    end

    test "does not list deleted resources associated to gateway", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )
      |> delete_resource(subject)

      assert list_resources_for_gateway(gateway, subject) == {:ok, []}
    end

    test "returns all resources for a given gateway and account user subject", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

      Fixtures.Resources.create_resource(account: account)

      assert {:ok, resources} = list_resources_for_gateway(gateway, subject)
      assert length(resources) == 2
    end

    test "returns error when subject has no permission to manage resources", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_resources_for_gateway(gateway, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Resources.Authorizer.manage_resources_permission(),
                      Resources.Authorizer.view_available_resources_permission()
                    ]}
                 ]}}
    end
  end

  describe "peek_resource_actor_groups/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns count of authorized groups and first 3 items", %{
      account: account,
      subject: subject
    } do
      resource1 = Fixtures.Resources.create_resource(account: account)
      Fixtures.Policies.create_policy(account: account, resource: resource1)
      Fixtures.Policies.create_policy(account: account, resource: resource1)
      Fixtures.Policies.create_policy(account: account, resource: resource1)
      Fixtures.Policies.create_policy(account: account, resource: resource1)

      resource2 = Fixtures.Resources.create_resource(account: account)

      assert {:ok, peek} = peek_resource_actor_groups([resource1, resource2], 3, subject)

      assert length(Map.keys(peek)) == 2

      assert peek[resource1.id].count == 4
      assert length(peek[resource1.id].items) == 3
      assert [%Actors.Group{} | _] = peek[resource1.id].items

      assert peek[resource2.id].count == 0
      assert Enum.empty?(peek[resource2.id].items)
    end

    test "preloads group providers", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      Fixtures.Policies.create_policy(account: account, resource: resource)

      assert {:ok, peek} = peek_resource_actor_groups([resource], 3, subject)
      assert [%Actors.Group{} = group] = peek[resource.id].items
      assert Ecto.assoc_loaded?(group.provider)
    end

    test "returns count of policies per resource and first LIMIT actors", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      Fixtures.Policies.create_policy(account: account, resource: resource)
      Fixtures.Policies.create_policy(account: account, resource: resource)

      other_resource = Fixtures.Resources.create_resource(account: account)
      Fixtures.Policies.create_policy(account: account, resource: other_resource)

      assert {:ok, peek} = peek_resource_actor_groups([resource], 1, subject)
      assert length(peek[resource.id].items) == 1
    end

    test "ignores deleted policies", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      policy = Fixtures.Policies.create_policy(account: account, resource: resource)
      Fixtures.Policies.delete_policy(policy)

      assert {:ok, peek} = peek_resource_actor_groups([resource], 3, subject)
      assert peek[resource.id].count == 0
      assert Enum.empty?(peek[resource.id].items)
    end

    test "ignores disabled policies", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      policy = Fixtures.Policies.create_policy(account: account, resource: resource)
      Fixtures.Policies.disable_policy(policy)

      assert {:ok, peek} = peek_resource_actor_groups([resource], 3, subject)
      assert peek[resource.id].count == 0
      assert Enum.empty?(peek[resource.id].items)
    end

    test "ignores not linked policies", %{
      account: account,
      subject: subject
    } do
      Fixtures.Policies.create_policy(account: account)
      Fixtures.Policies.create_policy(account: account)

      resource = Fixtures.Resources.create_resource(account: account)

      assert {:ok, peek} = peek_resource_actor_groups([resource], 1, subject)
      assert peek[resource.id].count == 0
      assert Enum.empty?(peek[resource.id].items)
    end

    test "returns empty map on empty actors", %{subject: subject} do
      assert peek_resource_actor_groups([], 1, subject) == {:ok, %{}}
    end

    test "returns empty map on empty groups", %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)
      assert {:ok, peek} = peek_resource_actor_groups([resource], 3, subject)
      assert length(Map.keys(peek)) == 1
      assert peek[resource.id].count == 0
      assert Enum.empty?(peek[resource.id].items)
    end

    test "does not allow peeking into other accounts", %{
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: other_account)
      Fixtures.Policies.create_policy(account: other_account, resource: resource)

      assert {:ok, peek} = peek_resource_actor_groups([resource], 3, subject)
      assert Map.has_key?(peek, resource.id)
      assert peek[resource.id].count == 0
      assert Enum.empty?(peek[resource.id].items)
    end

    test "returns error when subject has no permission to manage groups", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert peek_resource_actor_groups([], 3, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.manage_resources_permission()]}}
    end
  end

  describe "create_resource/2" do
    test "returns changeset error on empty attrs", %{subject: subject} do
      assert {:error, changeset} = create_resource(%{}, subject)

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               type: ["can't be blank"],
               connections: ["can't be blank"]
             }

      assert {:error, changeset} = create_resource(%{type: :dns}, subject)

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               connections: ["can't be blank"],
               address: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{subject: subject} do
      attrs = %{
        "name" => String.duplicate("a", 256),
        "address_description" => String.duplicate("a", 513),
        "filters" => :foo,
        "connections" => :bar
      }

      assert {:error, changeset} = create_resource(attrs, subject)

      assert errors_on(changeset) == %{
               address_description: ["should be at most 512 character(s)"],
               name: ["should be at most 255 character(s)"],
               type: ["can't be blank"],
               filters: ["is invalid"],
               connections: ["is invalid"]
             }
    end

    test "validates dns address", %{account: account, subject: subject} do
      attrs = %{"address" => String.duplicate("a", 256), "type" => "dns"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "should be at most 253 character(s)" in errors_on(changeset).address

      attrs = %{"address" => "a", "type" => "dns"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      for dns <- [
            "**.example.com",
            "example.com",
            "app.**.example.com",
            "app.bar.foo.example.com",
            "**.example.com",
            "foo.example.com",
            "**.example.com",
            "foo.bar.example.com",
            "*.example.com",
            "foo.example.com",
            "*.example.com",
            "example.com",
            "foo.*.example.com",
            "foo.bar.example.com",
            "app.*.*.example.com",
            "app.foo.bar.example.com",
            "app.f??.example.com",
            "app.foo.example.com",
            "app.example.com",
            "app.example.com",
            "*?*.example.com",
            "app.example.com",
            "app.**.web.**.example.com",
            "app.web.example.com",
            "app.*.example.com",
            "google.com",
            "myhost"
          ] do
        gateway = Fixtures.Gateways.create_gateway(account: account)

        attrs =
          Fixtures.Resources.resource_attrs(
            address: dns,
            connections: [
              %{gateway_group_id: gateway.group_id}
            ]
          )

        assert {:ok, _resource} = create_resource(attrs, subject)
      end

      attrs = Fixtures.Resources.resource_attrs(address: "localhost")
      assert {:error, changeset} = create_resource(attrs, subject)

      error =
        "localhost cannot be used as a TLD. Try adding a DNS alias to /etc/hosts on the Gateway(s) instead"

      assert error in errors_on(changeset).address

      attrs = Fixtures.Resources.resource_attrs(address: "a.localhost")
      assert {:error, changeset} = create_resource(attrs, subject)

      error =
        "localhost cannot be used as a TLD. Try adding a DNS alias to /etc/hosts on the Gateway(s) instead"

      assert error in errors_on(changeset).address

      attrs = Fixtures.Resources.resource_attrs(address: "*.com")
      assert {:error, changeset} = create_resource(attrs, subject)
      error = "second level domain for IANA TLDs cannot contain wildcards"
      assert error in errors_on(changeset).address

      attrs = Fixtures.Resources.resource_attrs(address: "foo.*")
      assert {:error, changeset} = create_resource(attrs, subject)
      error = "TLD cannot contain wildcards"
      assert error in errors_on(changeset).address
    end

    test "validates cidr address", %{subject: subject} do
      attrs = %{"address" => "192.168.1.256/28", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "is not a valid CIDR range" in errors_on(changeset).address

      attrs = %{"address" => "192.168.1.1", "type" => "ip"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      attrs = %{"address" => "100.64.0.0/8", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "cannot be in the CIDR 100.64.0.0/10" in errors_on(changeset).address

      attrs = %{"address" => "100.96.0.0/11", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "cannot be in the CIDR 100.64.0.0/10" in errors_on(changeset).address

      attrs = %{"address" => "fd00:2021:1111::/102", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "cannot be in the CIDR fd00:2021:1111::/48" in errors_on(changeset).address

      attrs = %{"address" => "fd00:2021:1111:8000::/96", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "cannot be in the CIDR fd00:2021:1111::/48" in errors_on(changeset).address

      internet_resource_message =
        "routing all traffic through Firezone is available on paid plans using the Internet Resource"

      attrs = %{"address" => "::/0", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "cannot contain loopback addresses" in errors_on(changeset).address
      assert internet_resource_message in errors_on(changeset).address

      attrs = %{"address" => "0.0.0.0/0", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "cannot contain loopback addresses" in errors_on(changeset).address
      assert internet_resource_message in errors_on(changeset).address
    end

    # We allow names to be duplicate because Resources are split into Sites
    # and there is no way to create a unique constraint for many-to-many (join table) relation
    # test "returns error on duplicate name", %{account: account, subject: subject} do
    #   gateway = Fixtures.Gateways.create_gateway(account: account)
    #   resource = Fixtures.Resources.create_resource(account: account, subject: subject)
    #   address = Fixtures.Resources.resource_attrs().address

    #   attrs = %{
    #     "name" => resource.name,
    #     "address" => address,
    #     "type" => "dns",
    #     "connections" => [%{"gateway_group_id" => gateway.group_id}]
    #   }

    #   assert {:error, changeset} = create_resource(attrs, subject)
    #   assert errors_on(changeset) == %{name: ["has already been taken"]}
    # end

    test "trims whitespace from address before validation", %{subject: subject} do
      attrs = %{"type" => "dns", "address" => " foo  "}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      attrs = %{"type" => "dns", "address" => "\tfoo\t"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      attrs = %{"type" => "dns", "address" => "\nfoo\n"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      attrs = %{"type" => "dns", "address" => "\rfoo\r"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)

      attrs = %{"type" => "dns", "address" => "\vfoo\v"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "creates a dns resource", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      attrs =
        Fixtures.Resources.resource_attrs(
          connections: [
            %{gateway_group_id: gateway.group_id}
          ]
        )

      assert {:ok, resource} = create_resource(attrs, subject)

      assert resource.address == attrs.address
      assert resource.address_description == attrs.address_description
      assert resource.name == attrs.address
      assert resource.account_id == account.id

      assert resource.created_by == :identity
      assert resource.created_by_identity_id == subject.identity.id

      assert [%Domain.Resources.Connection{} = connection] = resource.connections
      assert connection.resource_id == resource.id
      assert connection.gateway_group_id == gateway.group_id
      assert connection.account_id == account.id
      assert connection.created_by == :identity
      assert connection.created_by_identity_id == subject.identity.id

      assert [
               %Domain.Resources.Resource.Filter{ports: ["80", "433"], protocol: :tcp},
               %Domain.Resources.Resource.Filter{ports: ["100 - 200"], protocol: :udp},
               %Domain.Resources.Resource.Filter{protocol: :icmp}
             ] = resource.filters
    end

    test "creates a cidr resource", %{account: account, subject: subject} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      address_count = Repo.aggregate(Domain.Network.Address, :count)

      attrs =
        Fixtures.Resources.resource_attrs(
          connections: [
            %{gateway_group_id: gateway.group_id}
          ],
          type: :cidr,
          name: "mycidr",
          address: "192.168.1.1/28",
          address_description: "https://google.com"
        )

      assert {:ok, resource} = create_resource(attrs, subject)

      assert resource.address == "192.168.1.0/28"
      assert resource.address_description == attrs.address_description
      assert resource.name == attrs.name
      assert resource.account_id == account.id

      assert [
               %Domain.Resources.Connection{
                 resource_id: resource_id,
                 gateway_group_id: gateway_group_id,
                 account_id: account_id
               }
             ] = resource.connections

      assert resource_id == resource.id
      assert gateway_group_id == gateway.group_id
      assert account_id == account.id

      assert [
               %Domain.Resources.Resource.Filter{ports: ["80", "433"], protocol: :tcp},
               %Domain.Resources.Resource.Filter{ports: ["100 - 200"], protocol: :udp},
               %Domain.Resources.Resource.Filter{protocol: :icmp}
             ] = resource.filters

      assert Repo.aggregate(Domain.Network.Address, :count) == address_count
    end

    test "broadcasts an account message when resource is created", %{
      account: account,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)

      attrs =
        Fixtures.Resources.resource_attrs(
          connections: [
            %{gateway_group_id: gateway.group_id}
          ]
        )

      :ok = subscribe_to_events_for_account(account)

      assert {:ok, resource} = create_resource(attrs, subject)

      assert_receive {:create_resource, resource_id}
      assert resource_id == resource.id
    end

    test "returns error when subject has no permission to create resources", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_resource(%{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.manage_resources_permission()]}}
    end
  end

  describe "update_or_replace_resource/3" do
    setup context do
      resource =
        Fixtures.Resources.create_resource(
          account: context.account,
          subject: context.subject
        )

      Map.put(context, :resource, resource)
    end

    test "does nothing on empty attrs", %{resource: resource, subject: subject} do
      assert {:updated, _resource} = update_or_replace_resource(resource, %{}, subject)
    end

    test "returns error on invalid attrs", %{resource: resource, subject: subject} do
      attrs = %{
        "name" => String.duplicate("a", 256),
        "address_description" => String.duplicate("a", 513),
        "filters" => :foo,
        "connections" => :bar
      }

      assert {:error, changeset} = update_or_replace_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               address_description: ["should be at most 512 character(s)"],
               filters: ["is invalid"],
               connections: ["is invalid"]
             }
    end

    test "broadcasts an account message when resource is updated", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      :ok = subscribe_to_events_for_account(account)

      attrs = %{"name" => "foo"}
      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)

      assert_receive {:update_resource, resource_id}
      assert resource_id == resource.id
    end

    test "broadcasts a resource message when resource is updated", %{
      resource: resource,
      subject: subject
    } do
      :ok = subscribe_to_events_for_resource(resource)

      attrs = %{"name" => "foo"}
      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)

      assert_receive {:update_resource, resource_id}
      assert resource_id == resource.id
    end

    test "allows to update name", %{resource: resource, subject: subject} do
      attrs = %{"name" => "foo"}
      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)
      assert resource.name == "foo"
    end

    test "allows to update client address", %{resource: resource, subject: subject} do
      attrs = %{"address_description" => "http://#{resource.address}:1234/foo"}
      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)
      assert resource.address_description == attrs["address_description"]
    end

    test "does not expire flows when connections are not updated", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      flow = Fixtures.Flows.create_flow(account: account, resource: resource, subject: subject)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      attrs = %{"name" => "foo"}
      assert {:updated, _resource} = update_or_replace_resource(resource, attrs, subject)

      refute_receive {:expire_flow, _flow_id, _client_id, _resource_id}
    end

    test "allows to update connections", %{account: account, resource: resource, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway1 = Fixtures.Gateways.create_gateway(account: account, group: group)

      attrs = %{"connections" => [%{gateway_group_id: gateway1.group_id}]}
      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)
      gateway_group_ids = Enum.map(resource.connections, & &1.gateway_group_id)
      assert gateway_group_ids == [gateway1.group_id]

      gateway2 = Fixtures.Gateways.create_gateway(account: account)

      flow = Fixtures.Flows.create_flow(account: account, resource: resource, subject: subject)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      attrs = %{
        "connections" => [
          %{gateway_group_id: gateway1.group_id},
          %{gateway_group_id: gateway2.group_id}
        ]
      }

      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)
      gateway_group_ids = Enum.map(resource.connections, & &1.gateway_group_id)
      assert Enum.sort(gateway_group_ids) == Enum.sort([gateway1.group_id, gateway2.group_id])

      attrs = %{"connections" => [%{gateway_group_id: gateway2.group_id}]}
      assert {:updated, resource} = update_or_replace_resource(resource, attrs, subject)
      gateway_group_ids = Enum.map(resource.connections, & &1.gateway_group_id)
      assert gateway_group_ids == [gateway2.group_id]

      flow_id = flow.id
      resource_id = resource.id
      assert_receive {:expire_flow, ^flow_id, _client_id, ^resource_id}
    end

    test "does not allow to remove all connections", %{resource: resource, subject: subject} do
      attrs = %{"connections" => []}
      assert {:error, changeset} = update_or_replace_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               connections: ["can't be blank"]
             }
    end

    test "replaces the resource when address is changed", %{resource: resource, subject: subject} do
      attrs = %{"address" => "foo"}

      assert {:replaced, updated_resource, created_resource} =
               update_or_replace_resource(resource, attrs, subject)

      assert updated_resource.address == resource.address
      assert created_resource.address == attrs["address"]
    end

    test "broadcasts events and expires flows when resource is replaced", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      flow = Fixtures.Flows.create_flow(account: account, resource: resource, subject: subject)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)
      :ok = subscribe_to_events_for_account(account)

      attrs = %{"address" => "foo"}

      assert {:replaced, updated_resource, created_resource} =
               update_or_replace_resource(resource, attrs, subject)

      flow_id = flow.id
      updated_resource_id = updated_resource.id
      assert_receive {:expire_flow, ^flow_id, _client_id, ^updated_resource_id}
      assert_receive {:delete_resource, ^updated_resource_id}

      created_resource_id = created_resource.id
      assert_receive {:create_resource, ^created_resource_id}
    end

    test "replaces resource policies when resource is replaced", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      policy1 = Fixtures.Policies.create_policy(account: account, resource: resource)
      policy2 = Fixtures.Policies.create_policy(account: account, resource: resource)

      :ok = Domain.Policies.subscribe_to_events_for_account(account)

      attrs = %{"address" => "foo"}

      assert {:replaced, _updated_resource, created_resource} =
               update_or_replace_resource(resource, attrs, subject)

      assert Repo.get_by(Domain.Policies.Policy, id: policy1.id).deleted_at
      assert Repo.get_by(Domain.Policies.Policy, id: policy2.id).deleted_at

      assert_receive {:delete_policy, deleted_policy_id}
      assert deleted_policy_id in [policy1.id, policy2.id]

      assert_receive {:delete_policy, deleted_policy_id}
      assert deleted_policy_id in [policy1.id, policy2.id]

      assert_receive {:create_policy, created_policy_id}

      assert Repo.get_by(Domain.Policies.Policy, id: created_policy_id).resource_id ==
               created_resource.id

      assert_receive {:create_policy, created_policy_id}

      assert Repo.get_by(Domain.Policies.Policy, id: created_policy_id).resource_id ==
               created_resource.id
    end

    test "replaces the resource when type is changed", %{resource: resource, subject: subject} do
      attrs = %{"type" => "ip", "address" => "10.0.10.1"}

      assert {:replaced, updated_resource, created_resource} =
               update_or_replace_resource(resource, attrs, subject)

      assert updated_resource.type == resource.type
      assert created_resource.type == :ip
    end

    test "replaces the resource when filters are changed", %{resource: resource, subject: subject} do
      attrs = %{"filters" => []}

      assert {:replaced, updated_resource, created_resource} =
               update_or_replace_resource(resource, attrs, subject)

      assert updated_resource.filters == resource.filters
      assert created_resource.filters == attrs["filters"]
    end

    test "returns error when subject has no permission to create resources", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_or_replace_resource(resource, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.manage_resources_permission()]}}
    end
  end

  describe "delete_resource/2" do
    setup %{account: account, subject: subject} do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          subject: subject
        )

      %{resource: resource}
    end

    test "returns error on state conflict", %{
      resource: resource,
      subject: subject
    } do
      assert {:ok, deleted} = delete_resource(resource, subject)
      assert delete_resource(deleted, subject) == {:error, :not_found}
      assert delete_resource(resource, subject) == {:error, :not_found}
    end

    test "deletes resources", %{resource: resource, subject: subject} do
      assert {:ok, deleted} = delete_resource(resource, subject)
      assert deleted.deleted_at
    end

    test "deletes policies that use this resource", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      other_policy = Fixtures.Policies.create_policy(account: account)
      policy = Fixtures.Policies.create_policy(account: account, resource: resource)

      assert {:ok, _resource} = delete_resource(resource, subject)

      refute is_nil(Repo.get_by(Domain.Policies.Policy, id: policy.id).deleted_at)
      assert is_nil(Repo.get_by(Domain.Policies.Policy, id: other_policy.id).deleted_at)
    end

    test "deletes connections that use this resource", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
        )

      assert {:ok, _resource} = delete_resource(resource, subject)

      assert Repo.aggregate(Resources.Connection.Query.by_gateway_group_id(group.id), :count) == 0
    end

    test "broadcasts an account message when resource is deleted", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      :ok = subscribe_to_events_for_account(account)

      assert {:ok, resource} = delete_resource(resource, subject)

      assert_receive {:delete_resource, resource_id}
      assert resource_id == resource.id
    end

    test "broadcasts a resource message when resource is deleted", %{
      resource: resource,
      subject: subject
    } do
      :ok = subscribe_to_events_for_resource(resource)

      assert {:ok, resource} = delete_resource(resource, subject)

      assert_receive {:delete_resource, resource_id}
      assert resource_id == resource.id
    end

    test "returns error when subject has no permission to delete resources", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_resource(resource, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.manage_resources_permission()]}}
    end
  end

  describe "delete_connections_for/2" do
    setup %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
        )

      %{
        group: group,
        resource: resource
      }
    end

    test "does nothing on state conflict", %{
      group: group,
      subject: subject
    } do
      assert delete_connections_for(group, subject) == {:ok, 1}
      assert delete_connections_for(group, subject) == {:ok, 0}
    end

    test "deletes connections for actor group", %{group: group, subject: subject} do
      assert delete_connections_for(group, subject) == {:ok, 1}
      assert Repo.aggregate(Resources.Connection.Query.by_gateway_group_id(group.id), :count) == 0
    end

    test "returns error when subject has no permission to manage resources", %{
      group: group,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_connections_for(group, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Resources.Authorizer.manage_resources_permission()]}}
    end
  end

  describe "connected?/2" do
    test "returns true when resource has a connection to a gateway", %{
      account: account,
      subject: subject
    } do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: group.id}]
        )

      assert connected?(resource, gateway)
    end

    test "raises resource and gateway don't belong to the same account" do
      gateway = Fixtures.Gateways.create_gateway()
      resource = Fixtures.Resources.create_resource()

      assert_raise FunctionClauseError, fn ->
        connected?(resource, gateway)
      end
    end

    test "returns false when resource has no connection to a gateway", %{account: account} do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      resource = Fixtures.Resources.create_resource(account: account)

      refute connected?(resource, gateway)
    end
  end
end
