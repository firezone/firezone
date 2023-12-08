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

  describe "fetch_resource_by_id/2" do
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
      assert is_nil(fetched_resource.authorized_by_policy)
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
      assert fetched_resource.authorized_by_policy.id == policy.id
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
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Resources.Authorizer.manage_resources_permission(),
                        Resources.Authorizer.view_available_resources_permission()
                      ]}
                   ]
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

  describe "fetch_and_authorize_resource_by_id/2" do
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
      assert fetched_resource.authorized_by_policy.id == policy.id
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
      assert fetched_resource.authorized_by_policy.id == policy.id
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
      assert fetched_resource.authorized_by_policy.id in [policy1.id, policy2.id]
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

    test "does not authorize using deleted group", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      actor_group =
        Fixtures.Actors.create_group(account: account)
        |> Fixtures.Actors.delete_group()

      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

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
                 [
                   missing_permissions: [
                     Resources.Authorizer.view_available_resources_permission()
                   ]
                 ]}}
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

  describe "list_authorized_resources/1" do
    test "returns empty list when there are no resources", %{subject: subject} do
      assert list_authorized_resources(subject) == {:ok, []}
    end

    test "returns empty list when there are no authorized resources", %{
      account: account,
      subject: subject
    } do
      Fixtures.Resources.create_resource(account: account)
      assert list_authorized_resources(subject) == {:ok, []}
    end

    test "does not list deleted resources", %{
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

      {:ok, _resource} = delete_resource(resource, subject)

      assert list_authorized_resources(subject) == {:ok, []}
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

      assert list_authorized_resources(subject) == {:ok, []}
    end

    test "returns authorized resources for account user subject", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      resource1 = Fixtures.Resources.create_resource(account: account)
      resource2 = Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource()

      assert {:ok, []} = list_authorized_resources(subject)

      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource1
        )

      assert {:ok, resources} = list_authorized_resources(subject)
      assert length(resources) == 1
      assert hd(resources).authorized_by_policy.id == policy.id

      policy2 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource2
        )

      assert {:ok, resources2} = list_authorized_resources(subject)
      assert length(resources2) == 2

      assert hd(resources2 -- resources).authorized_by_policy.id == policy2.id
    end

    test "returns authorized resources for account admin subject", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      resource1 = Fixtures.Resources.create_resource(account: account)
      resource2 = Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource()

      assert {:ok, []} = list_authorized_resources(subject)

      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource1
        )

      assert {:ok, resources} = list_authorized_resources(subject)
      assert length(resources) == 1
      assert hd(resources).authorized_by_policy.id == policy.id

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource2
      )

      assert {:ok, resources} = list_authorized_resources(subject)
      assert length(resources) == 2
    end

    test "returns error when subject has no permission to manage resources", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_authorized_resources(subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     Resources.Authorizer.view_available_resources_permission()
                   ]
                 ]}}
    end
  end

  describe "list_resources/1" do
    test "returns empty list when there are no resources", %{subject: subject} do
      assert list_resources(subject) == {:ok, []}
    end

    test "does not list resources from other accounts", %{
      subject: subject
    } do
      Fixtures.Resources.create_resource()
      assert list_resources(subject) == {:ok, []}
    end

    test "does not list deleted resources", %{
      account: account,
      subject: subject
    } do
      Fixtures.Resources.create_resource(account: account)
      |> delete_resource(subject)

      assert list_resources(subject) == {:ok, []}
    end

    test "returns all resources for account admin subject", %{
      account: account,
      subject: subject
    } do
      Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource(account: account)
      Fixtures.Resources.create_resource()

      assert {:ok, resources} = list_resources(subject)
      assert length(resources) == 2
    end

    test "returns error when subject has no permission to manage resources", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_resources(subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     Resources.Authorizer.manage_resources_permission()
                   ]
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
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Resources.Authorizer.manage_resources_permission(),
                        Resources.Authorizer.view_available_resources_permission()
                      ]}
                   ]
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

    test "ignores other policies", %{
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
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
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
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Resources.Authorizer.manage_resources_permission(),
                        Resources.Authorizer.view_available_resources_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "create_resource/2" do
    test "returns changeset error on empty attrs", %{subject: subject} do
      assert {:error, changeset} = create_resource(%{}, subject)

      assert errors_on(changeset) == %{
               address: ["can't be blank"],
               type: ["can't be blank"],
               connections: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{subject: subject} do
      attrs = %{"name" => String.duplicate("a", 256), "filters" => :foo, "connections" => :bar}
      assert {:error, changeset} = create_resource(attrs, subject)

      assert errors_on(changeset) == %{
               address: ["can't be blank"],
               name: ["should be at most 255 character(s)"],
               type: ["can't be blank"],
               filters: ["is invalid"],
               connections: ["is invalid"]
             }
    end

    test "validates dns address", %{subject: subject} do
      attrs = %{"address" => String.duplicate("a", 256), "type" => "dns"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "should be at most 253 character(s)" in errors_on(changeset).address

      attrs = %{"address" => "a", "type" => "dns"}
      assert {:error, changeset} = create_resource(attrs, subject)
      refute Map.has_key?(errors_on(changeset), :address)
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
      assert "can not be in the CIDR 100.64.0.0/11" in errors_on(changeset).address

      attrs = %{"address" => "fd00:2021:1111::/102", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "can not be in the CIDR fd00:2021:1111::/107" in errors_on(changeset).address

      attrs = %{"address" => "::/0", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "can not contain loopback addresses" in errors_on(changeset).address
      assert "can not contain all IPv6 addresses" in errors_on(changeset).address

      attrs = %{"address" => "0.0.0.0/0", "type" => "cidr"}
      assert {:error, changeset} = create_resource(attrs, subject)
      assert "can not contain loopback addresses" in errors_on(changeset).address
      assert "can not contain all IPv4 addresses" in errors_on(changeset).address
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
               %Domain.Resources.Resource.Filter{ports: ["100 - 200"], protocol: :udp}
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
          address: "192.168.1.1/28"
        )

      assert {:ok, resource} = create_resource(attrs, subject)

      assert resource.address == "192.168.1.0/28"
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
               %Domain.Resources.Resource.Filter{ports: ["100 - 200"], protocol: :udp}
             ] = resource.filters

      assert Repo.aggregate(Domain.Network.Address, :count) == address_count
    end

    test "returns error when subject has no permission to create resources", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_resource(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
    end
  end

  describe "update_resource/3" do
    setup context do
      resource =
        Fixtures.Resources.create_resource(
          account: context.account,
          subject: context.subject
        )

      Map.put(context, :resource, resource)
    end

    test "does nothing on empty attrs", %{resource: resource, subject: subject} do
      assert {:ok, _resource} = update_resource(resource, %{}, subject)
    end

    test "returns error on invalid attrs", %{resource: resource, subject: subject} do
      attrs = %{"name" => String.duplicate("a", 256), "filters" => :foo, "connections" => :bar}
      assert {:error, changeset} = update_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               filters: ["is invalid"],
               connections: ["is invalid"]
             }
    end

    test "allows to update name", %{resource: resource, subject: subject} do
      attrs = %{"name" => "foo"}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      assert resource.name == "foo"
    end

    test "allows to update filters", %{resource: resource, subject: subject} do
      attrs = %{"filters" => []}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      assert resource.filters == []
    end

    test "allows to update connections", %{account: account, resource: resource, subject: subject} do
      gateway1 = Fixtures.Gateways.create_gateway(account: account)

      attrs = %{"connections" => [%{gateway_group_id: gateway1.group_id}]}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      gateway_group_ids = Enum.map(resource.connections, & &1.gateway_group_id)
      assert gateway_group_ids == [gateway1.group_id]

      gateway2 = Fixtures.Gateways.create_gateway(account: account)

      attrs = %{
        "connections" => [
          %{gateway_group_id: gateway1.group_id},
          %{gateway_group_id: gateway2.group_id}
        ]
      }

      assert {:ok, resource} = update_resource(resource, attrs, subject)
      gateway_group_ids = Enum.map(resource.connections, & &1.gateway_group_id)
      assert Enum.sort(gateway_group_ids) == Enum.sort([gateway1.group_id, gateway2.group_id])

      attrs = %{"connections" => [%{gateway_group_id: gateway2.group_id}]}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      gateway_group_ids = Enum.map(resource.connections, & &1.gateway_group_id)
      assert gateway_group_ids == [gateway2.group_id]
    end

    test "does not allow to remove all connections", %{resource: resource, subject: subject} do
      attrs = %{"connections" => []}
      assert {:error, changeset} = update_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               connections: ["can't be blank"]
             }
    end

    test "does not allow to update address", %{resource: resource, subject: subject} do
      attrs = %{"address" => "foo"}
      assert {:ok, updated_resource} = update_resource(resource, attrs, subject)
      assert updated_resource.address == resource.address
    end

    test "returns error when subject has no permission to create resources", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_resource(resource, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
    end
  end

  describe "delete_resource/2" do
    setup context do
      resource =
        Fixtures.Resources.create_resource(
          account: context.account,
          subject: context.subject
        )

      Map.put(context, :resource, resource)
    end

    test "returns error on state conflict", %{
      resource: resource,
      subject: subject
    } do
      assert {:ok, deleted} = delete_resource(resource, subject)
      assert delete_resource(deleted, subject) == {:error, :not_found}
      assert delete_resource(resource, subject) == {:error, :not_found}
    end

    test "deletes gateways", %{resource: resource, subject: subject} do
      assert {:ok, deleted} = delete_resource(resource, subject)
      assert deleted.deleted_at
    end

    test "returns error when subject has no permission to delete resources", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_resource(resource, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Resources.Authorizer.manage_resources_permission()]]}}
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
