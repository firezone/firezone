defmodule Domain.FlowsTest do
  use Domain.DataCase, async: true
  import Domain.Flows
  alias Domain.Flows

  setup do
    account = Fixtures.Accounts.create_account()

    actor_group = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)

    client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

    gateway_group = Fixtures.Gateways.create_group(account: account)

    gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    policy =
      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

    %{
      account: account,
      actor_group: actor_group,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client,
      gateway_group: gateway_group,
      gateway: gateway,
      resource: resource,
      policy: policy
    }
  end

  describe "authorize_flow/4" do
    test "returns error when resource does not exist", %{
      client: client,
      gateway: gateway,
      subject: subject
    } do
      resource_id = Ecto.UUID.generate()
      assert authorize_flow(client, gateway, resource_id, subject) == {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{
      client: client,
      gateway: gateway,
      subject: subject
    } do
      assert authorize_flow(client, gateway, "foo", subject) == {:error, :not_found}
    end

    test "returns authorized resource", %{
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      assert {:ok, fetched_resource, _flow} =
               authorize_flow(client, gateway, resource.id, subject)

      assert fetched_resource.id == resource.id
      assert fetched_resource.authorized_by_policy.id == policy.id
    end

    test "creates a network flow", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      assert {:ok, _fetched_resource, %Flows.Flow{} = flow} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.source_remote_ip.address == subject.context.remote_ip
      assert flow.source_user_agent == subject.context.user_agent
      assert flow.destination_remote_ip == gateway.last_seen_remote_ip
      assert flow.expires_at == subject.expires_at
    end

    test "does not return authorized access to deleted resources", %{
      client: client,
      gateway: gateway,
      resource: resource,
      subject: subject
    } do
      {:ok, resource} = Domain.Resources.delete_resource(resource, subject)

      assert authorize_flow(client, gateway, resource.id, subject) == {:error, :not_found}
    end

    test "does not authorize access to resources in other accounts", %{
      client: client,
      gateway: gateway,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource()
      assert authorize_flow(client, gateway, resource.id, subject) == {:error, :not_found}
    end

    test "raises on account_id mismatch", %{
      client: client,
      gateway: gateway,
      resource: resource,
      subject: subject
    } do
      other_subject = Fixtures.Auth.create_subject()
      other_client = Fixtures.Clients.create_client()
      other_gateway = Fixtures.Gateways.create_gateway()

      assert_raise FunctionClauseError, fn ->
        authorize_flow(client, gateway, resource.id, other_subject)
      end

      assert_raise FunctionClauseError, fn ->
        authorize_flow(client, other_gateway, resource.id, subject)
      end

      assert_raise FunctionClauseError, fn ->
        authorize_flow(other_client, gateway, resource.id, subject)
      end
    end

    test "returns error when subject has no permission to create flows", %{
      client: client,
      gateway: gateway,
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert authorize_flow(client, gateway, resource.id, subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     Flows.Authorizer.create_flows_permission()
                   ]
                 ]}}

      subject = Fixtures.Auth.add_permission(subject, Flows.Authorizer.create_flows_permission())

      assert authorize_flow(client, gateway, resource.id, subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     Domain.Resources.Authorizer.view_available_resources_permission()
                   ]
                 ]}}
    end

    test "preloads assocs", %{
      client: client,
      gateway: gateway,
      resource: resource,
      subject: subject
    } do
      assert {:ok, resource, _flow} =
               authorize_flow(client, gateway, resource.id, subject, preload: :connections)

      assert Ecto.assoc_loaded?(resource.connections) == true
      assert length(resource.connections) == 1
    end
  end

  describe "list_flows_for/2" do
    test "returns empty list when there are no flows", %{
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      assert list_flows_for(policy, subject) == {:ok, []}
      assert list_flows_for(resource, subject) == {:ok, []}
      assert list_flows_for(client, subject) == {:ok, []}
      assert list_flows_for(gateway, subject) == {:ok, []}
    end

    test "does not list flows from other accounts", %{
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      Fixtures.Flows.create_flow()

      assert list_flows_for(policy, subject) == {:ok, []}
      assert list_flows_for(resource, subject) == {:ok, []}
      assert list_flows_for(client, subject) == {:ok, []}
      assert list_flows_for(gateway, subject) == {:ok, []}
    end

    test "returns all authorized resources for account user subject", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert list_flows_for(policy, subject) == {:ok, [flow]}
      assert list_flows_for(resource, subject) == {:ok, [flow]}
      assert list_flows_for(client, subject) == {:ok, [flow]}
      assert list_flows_for(gateway, subject) == {:ok, [flow]}
    end

    test "returns error when subject has no permission to view flows", %{
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      expected_error =
        {:error,
         {:unauthorized, [missing_permissions: [Flows.Authorizer.view_flows_permission()]]}}

      assert list_flows_for(policy, subject) == expected_error
      assert list_flows_for(resource, subject) == expected_error
      assert list_flows_for(client, subject) == expected_error
      assert list_flows_for(gateway, subject) == expected_error
    end
  end
end
