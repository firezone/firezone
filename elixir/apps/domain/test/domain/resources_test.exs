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

    test "does not return deleted resources", %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)
      delete_resource(resource, subject)

      assert {:error, :not_found} = fetch_resource_by_id(resource.id, subject)
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

    test "does not return deleted resources", %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)
      delete_resource(resource, subject)

      assert {:error, :not_found} = fetch_resource_by_id_or_persistent_id(resource.id, subject)

      assert {:error, :not_found} =
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
    setup context do
      gateway_group =
        Fixtures.Gateways.create_group(account: context.account, subject: context.subject)

      Map.put(context, :gateway_group, gateway_group)
    end

    test "prevents setting ip_stack for ipv4 resource", %{
      subject: subject,
      gateway_group: gateway_group
    } do
      attrs =
        Fixtures.Resources.resource_attrs(
          type: :ip,
          address: "1.1.1.1",
          ip_stack: :dual,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:error, changeset} = create_resource(attrs, subject)

      assert %{
               ip_stack: [
                 "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
               ]
             } = errors_on(changeset)
    end

    test "prevents setting ip_stack for cidr4 resource", %{
      subject: subject,
      gateway_group: gateway_group
    } do
      attrs =
        Fixtures.Resources.resource_attrs(
          type: :cidr,
          address: "10.0.0.0/24",
          ip_stack: :dual,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:error, changeset} = create_resource(attrs, subject)

      assert %{
               ip_stack: [
                 "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
               ]
             } = errors_on(changeset)
    end

    test "prevents setting ip_stack for ipv6 resource", %{
      subject: subject,
      gateway_group: gateway_group
    } do
      attrs =
        Fixtures.Resources.resource_attrs(
          type: :ip,
          address: "2001:db8::1",
          ip_stack: :dual,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:error, changeset} = create_resource(attrs, subject)

      assert %{
               ip_stack: [
                 "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
               ]
             } = errors_on(changeset)
    end

    test "prevents setting ip_stack for cidr6 resource", %{
      subject: subject,
      gateway_group: gateway_group
    } do
      attrs =
        Fixtures.Resources.resource_attrs(
          type: :cidr,
          address: "2001:db8::/32",
          ip_stack: :dual,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:error, changeset} = create_resource(attrs, subject)

      assert %{
               ip_stack: [
                 "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
               ]
             } = errors_on(changeset)
    end

    test "prevents setting ip_stack for internet resource", %{account: account, subject: subject} do
      {:ok, gateway_group} = Domain.Gateways.create_internet_group(account)

      attrs =
        Fixtures.Resources.resource_attrs(
          type: :internet,
          ip_stack: :dual,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:error, changeset} = create_resource(attrs, subject)

      assert %{
               ip_stack: [
                 "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
               ]
             } = errors_on(changeset)
    end

    test "allows setting ip_stack for dns resources", %{
      subject: subject,
      gateway_group: gateway_group
    } do
      attrs =
        Fixtures.Resources.resource_attrs(
          type: :dns,
          address: "example.com",
          ip_stack: :dual,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:ok, resource} = create_resource(attrs, subject)
      assert resource.ip_stack == :dual

      attrs =
        Fixtures.Resources.resource_attrs(
          type: :dns,
          address: "example.com",
          ip_stack: :ipv4_only,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:ok, resource} = create_resource(attrs, subject)
      assert resource.ip_stack == :ipv4_only

      attrs =
        Fixtures.Resources.resource_attrs(
          type: :dns,
          address: "example.com",
          ip_stack: :ipv6_only,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:ok, resource} = create_resource(attrs, subject)
      assert resource.ip_stack == :ipv6_only
    end

    test "populates ip_stack for dns resources with 'dual' by default", %{
      subject: subject,
      gateway_group: gateway_group
    } do
      attrs =
        Fixtures.Resources.resource_attrs(
          type: :dns,
          address: "example.com",
          ip_stack: nil,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:ok, resource} = create_resource(attrs, subject)
      assert resource.ip_stack == :dual
    end

    test "prevents adding other resources to the internet site", %{
      account: account,
      subject: subject
    } do
      {:ok, gateway_group} = Domain.Gateways.create_internet_group(account)

      attrs =
        Fixtures.Resources.resource_attrs(
          type: :dns,
          address: "example.com",
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      assert {:error, changeset} = create_resource(attrs, subject)

      assert %{resource: ["type must be 'internet' for the Internet site"]} in errors_on(
               changeset
             ).connections
    end

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
      error = "domain for IANA TLDs cannot consist solely of wildcards"
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

      assert resource.created_by_subject == %{
               "name" => subject.actor.name,
               "email" => subject.identity.email
             }

      assert [%Domain.Resources.Connection{} = connection] = resource.connections
      assert connection.resource_id == resource.id
      assert connection.gateway_group_id == gateway.group_id
      assert connection.account_id == account.id
      assert connection.created_by == :identity

      assert resource.created_by_subject == %{
               "name" => subject.actor.name,
               "email" => subject.identity.email
             }

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
      attrs = %{
        "name" => String.duplicate("a", 256),
        "address_description" => String.duplicate("a", 513),
        "filters" => :foo,
        "connections" => :bar
      }

      assert {:error, changeset} = update_resource(resource, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               address_description: ["should be at most 512 character(s)"],
               filters: ["is invalid"],
               connections: ["is invalid"]
             }
    end

    test "allows to update name", %{resource: resource, subject: subject} do
      attrs = %{"name" => "foo"}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      assert resource.name == "foo"
    end

    test "allows to update resource address", %{resource: resource, subject: subject} do
      attrs = %{"address_description" => "http://#{resource.address}:1234/foo"}
      assert {:ok, resource} = update_resource(resource, attrs, subject)
      assert resource.address_description == attrs["address_description"]
    end

    test "allows to update connections", %{account: account, resource: resource, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account, subject: subject)
      gateway1 = Fixtures.Gateways.create_gateway(account: account, group: group)

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

    test "updates the resource when address is changed", %{resource: resource, subject: subject} do
      attrs = %{"address" => "foo"}

      assert {:ok, updated_resource} = update_resource(resource, attrs, subject)

      assert updated_resource.address == attrs["address"]
      refute updated_resource.address == resource.address
    end

    test "updates the resource when type is changed", %{resource: resource, subject: subject} do
      attrs = %{"type" => "ip", "address" => "10.0.10.1"}

      assert {:ok, updated_resource} = update_resource(resource, attrs, subject)

      assert updated_resource.id == resource.id
      refute updated_resource.type == resource.type
      assert updated_resource.type == :ip
      assert updated_resource.address == attrs["address"]
    end

    test "updates the resource when filters are changed", %{resource: resource, subject: subject} do
      attrs = %{"filters" => []}

      assert {:ok, updated_resource} = update_resource(resource, attrs, subject)

      refute updated_resource.filters == resource.filters
      assert updated_resource.filters == attrs["filters"]
    end

    test "returns error when subject has no permission to create resources", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_resource(resource, %{}, subject) ==
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

    test "raises error when deleting stale resource structs", %{
      resource: resource,
      subject: subject
    } do
      assert {:ok, _resource} = delete_resource(resource, subject)

      assert_raise Ecto.StaleEntryError, fn ->
        delete_resource(resource, subject)
      end
    end

    test "deletes resources", %{resource: resource, subject: subject} do
      assert {:ok, _resource} = delete_resource(resource, subject)
      refute Repo.get(Resources.Resource, resource.id)
    end

    test "deletes policies that use this resource", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      other_policy = Fixtures.Policies.create_policy(account: account)
      policy = Fixtures.Policies.create_policy(account: account, resource: resource)

      assert {:ok, _resource} = delete_resource(resource, subject)

      assert is_nil(Repo.get(Domain.Policies.Policy, policy.id))
      assert Repo.get(Domain.Policies.Policy, other_policy.id) == other_policy
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

    test "returns error when subject has no permission to delete resources", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_resource(resource, subject) ==
               {:error,
                {:unauthorized,
                 [
                   reason: :missing_permissions,
                   missing_permissions: [
                     %Domain.Auth.Permission{resource: Domain.Resources.Resource, action: :manage}
                   ]
                 ]}}
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

  describe "adapt_resource_for_version/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      ip_resource =
        Fixtures.Resources.create_resource(type: :ip, account: account, address: "1.1.1.1")

      cidr_resource =
        Fixtures.Resources.create_resource(type: :cidr, account: account, address: "1.1.1.1/32")

      dns_resource =
        Fixtures.Resources.create_resource(
          type: :dns,
          account: account
        )

      internet_group = Fixtures.Gateways.create_internet_group(account: account)

      internet_resource =
        Fixtures.Resources.create_internet_resource(
          connections: [%{gateway_group_id: internet_group.id}],
          account: account
        )

      %{
        account: account,
        ip_resource: ip_resource,
        cidr_resource: cidr_resource,
        dns_resource: dns_resource,
        internet_resource: internet_resource
      }
    end

    test "for ip resource returns the same resource for all versions", %{ip_resource: ip_resource} do
      versions = ~w(
        1.0.0
        1.1.0
        1.2.0
        1.3.0
        1.4.0
        1.5.0
        1.6.0
      )

      for version <- versions do
        assert adapt_resource_for_version(ip_resource, version) == ip_resource
      end
    end

    test "for cidr resource returns the same resource for all versions", %{
      cidr_resource: cidr_resource
    } do
      versions = ~w(
        1.0.0
        1.1.0
        1.2.0
        1.3.0
        1.4.0
        1.5.0
        1.6.0
      )

      for version <- versions do
        assert adapt_resource_for_version(cidr_resource, version) == cidr_resource
      end
    end

    test "for dns resource transforms the address for versions < 1.2.0", %{
      dns_resource: dns_resource
    } do
      addresses = [
        {"**.example.com", "*.example.com"},
        {"*.example.com", "?.example.com"},
        {"foo.bar.example.com", "foo.bar.example.com"}
      ]

      versions = ~w(
        1.0.0
        1.1.0
      )

      for version <- versions do
        for address <- addresses do
          dns_resource = %{dns_resource | address: elem(address, 0)}
          adapted = adapt_resource_for_version(dns_resource, version)

          assert adapted.address == elem(address, 1)
        end
      end
    end

    test "for dns resource returns nil for incompatible addresses", %{
      dns_resource: dns_resource
    } do
      addresses = ~w(
        foo.?.example.com
        foo.bar*bar.example.com
      )

      versions = ~w(
        1.0.0
        1.1.0
      )

      for version <- versions do
        for address <- addresses do
          dns_resource = %{dns_resource | address: address}
          assert nil == adapt_resource_for_version(dns_resource, version)
        end
      end
    end

    test "for internet resource returns nil for versions < 1.3.0", %{
      internet_resource: internet_resource
    } do
      versions = ~w(
        1.0.0
        1.1.0
        1.2.0
      )

      for version <- versions do
        assert nil == adapt_resource_for_version(internet_resource, version)
      end
    end

    test "for internet resource returns resource as-is for versions >= 1.3.0", %{
      internet_resource: internet_resource
    } do
      versions = ~w(
        1.3.0
        1.4.0
        1.5.0
        1.6.0
      )

      for version <- versions do
        assert adapt_resource_for_version(internet_resource, version) == internet_resource
      end
    end
  end
end
