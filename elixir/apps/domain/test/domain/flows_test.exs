defmodule Domain.FlowsTest do
  use Domain.DataCase, async: true
  import Domain.Flows
  alias Domain.Flows
  alias Domain.Flows.Authorizer

  setup do
    account = Fixtures.Accounts.create_account()

    group = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    membership =
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    provider = Fixtures.Auth.create_email_provider(account: account)

    identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
    subject = Fixtures.Auth.create_subject(identity: identity)

    client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

    site = Fixtures.Sites.create_site(account: account)

    gateway = Fixtures.Gateways.create_gateway(account: account, site: site)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{site_id: site.id}]
      )

    policy =
      Fixtures.Policies.create_policy(
        account: account,
        group: group,
        resource: resource
      )

    %{
      account: account,
      group: group,
      actor: actor,
      provider: provider,
      membership: membership,
      identity: identity,
      subject: subject,
      client: client,
      site: site,
      gateway: gateway,
      resource: resource,
      policy: policy
    }
  end

  describe "create_flow/7" do
    test "creates a new flow for users", %{
      account: account,
      gateway: gateway,
      resource: resource,
      policy: policy,
      group: group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)

      membership =
        Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

      assert {:ok, %Flows.Flow{} = flow} =
               create_flow(
                 client,
                 gateway,
                 resource.id,
                 policy.id,
                 membership.id,
                 subject,
                 subject.expires_at
               )

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.client_remote_ip.address == subject.context.remote_ip
      assert flow.client_user_agent == subject.context.user_agent
      assert flow.gateway_remote_ip == gateway.last_seen_remote_ip
      assert flow.membership_id == membership.id
      assert flow.expires_at == subject.expires_at
    end

    test "creates a new flow for service accounts", %{
      account: account,
      group: group,
      gateway: gateway,
      resource: resource,
      policy: policy
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)

      membership =
        Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

      assert {:ok, %Flows.Flow{} = flow} =
               create_flow(
                 client,
                 gateway,
                 resource.id,
                 policy.id,
                 membership.id,
                 subject,
                 subject.expires_at
               )

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.client_remote_ip.address == subject.context.remote_ip
      assert flow.client_user_agent == subject.context.user_agent
      assert flow.gateway_remote_ip == gateway.last_seen_remote_ip
      assert flow.membership_id == membership.id
      assert flow.expires_at == subject.expires_at
    end
  end

  describe "reauthorize_flow/1" do
    test "when another valid policy exists for the resource",
         %{
           account: account,
           actor: actor,
           membership: membership,
           subject: subject,
           client: client,
           gateway: gateway,
           resource: resource,
           policy: policy
         } do
      other_group = Fixtures.Actors.create_group(account: account)

      Fixtures.Actors.create_membership(
        account: account,
        actor: actor,
        group: other_group
      )

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      Fixtures.Policies.create_policy(
        account: account,
        group: other_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: [client.last_seen_remote_ip_location_region]
          }
        ]
      )

      assert {:ok, reauthorized_flow} = reauthorize_flow(flow)
      assert reauthorized_flow.resource_id == flow.resource_id
    end

    test "when no more valid policies exist for the resource",
         %{
           account: account,
           actor: actor,
           membership: membership,
           subject: subject,
           client: client,
           gateway: gateway,
           resource: resource,
           policy: policy
         } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      other_group = Fixtures.Actors.create_group(account: account)

      Fixtures.Actors.create_membership(
        account: account,
        actor: actor,
        group: other_group
      )

      Repo.delete_all(Domain.Policy)

      Fixtures.Policies.create_policy(
        account: account,
        group: other_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["AU"]
          }
        ]
      )

      assert :error = reauthorize_flow(flow)
    end
  end

  describe "fetch_flow_by_id/3" do
    test "returns error when flow does not exist", %{subject: subject} do
      assert fetch_flow_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_flow_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns flow", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert {:ok, fetched_flow} = fetch_flow_by_id(flow.id, subject)
      assert fetched_flow.id == flow.id
    end

    test "does not return flows in other accounts", %{subject: subject} do
      flow = Fixtures.Flows.create_flow()
      assert fetch_flow_by_id(flow.id, subject) == {:error, :not_found}
    end

    test "returns error when subject has no permission to view flows", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_flow_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_flows_permission()]}}
    end

    test "associations are preloaded when opts given", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert {:ok, flow} =
               fetch_flow_by_id(flow.id, subject,
                 preload: [
                   :policy,
                   :client,
                   :gateway,
                   :resource,
                   :account
                 ]
               )

      assert Ecto.assoc_loaded?(flow.policy)
      assert Ecto.assoc_loaded?(flow.client)
      assert Ecto.assoc_loaded?(flow.gateway)
      assert Ecto.assoc_loaded?(flow.resource)
      assert Ecto.assoc_loaded?(flow.account)
    end
  end

  describe "all_gateway_flows_for_cache!/1" do
    test "returns all flows for client_id/resource_id pair", %{
      account: account,
      client: client,
      gateway: gateway,
      membership: membership,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert flow1.client_id == flow2.client_id
      assert flow1.resource_id == flow2.resource_id

      assert DateTime.compare(flow2.inserted_at, flow1.inserted_at) == :gt

      flows = all_gateway_flows_for_cache!(gateway)

      assert {{flow1.client_id, flow1.resource_id}, {flow1.id, flow1.expires_at}} in flows
      assert {{flow2.client_id, flow2.resource_id}, {flow2.id, flow2.expires_at}} in flows
    end
  end

  describe "list_flows_for/3" do
    test "returns empty list when there are no flows", %{
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      assert {:ok, [], _metadata} = list_flows_for(policy, subject)
      assert {:ok, [], _metadata} = list_flows_for(resource, subject)
      assert {:ok, [], _metadata} = list_flows_for(actor, subject)
      assert {:ok, [], _metadata} = list_flows_for(client, subject)
      assert {:ok, [], _metadata} = list_flows_for(gateway, subject)
    end

    test "does not list flows from other accounts", %{
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      Fixtures.Flows.create_flow()

      assert {:ok, [], _metadata} = list_flows_for(policy, subject)
      assert {:ok, [], _metadata} = list_flows_for(resource, subject)
      assert {:ok, [], _metadata} = list_flows_for(actor, subject)
      assert {:ok, [], _metadata} = list_flows_for(client, subject)
      assert {:ok, [], _metadata} = list_flows_for(gateway, subject)
    end

    test "returns all authorized flows for a given entity", %{
      account: account,
      actor: actor,
      client: client,
      gateway: gateway,
      membership: membership,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert {:ok, [^flow], _metadata} = list_flows_for(policy, subject)
      assert {:ok, [^flow], _metadata} = list_flows_for(resource, subject)
      assert {:ok, [^flow], _metadata} = list_flows_for(actor, subject)
      assert {:ok, [^flow], _metadata} = list_flows_for(client, subject)
      assert {:ok, [^flow], _metadata} = list_flows_for(gateway, subject)
    end

    test "does not return authorized flow of other entities", %{
      account: account,
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      other_client = Fixtures.Clients.create_client(account: account)
      Fixtures.Flows.create_flow(account: account, client: other_client, subject: subject)

      assert {:ok, [], _metadata} = list_flows_for(policy, subject)
      assert {:ok, [], _metadata} = list_flows_for(resource, subject)
      assert {:ok, [], _metadata} = list_flows_for(actor, subject)
      assert {:ok, [], _metadata} = list_flows_for(client, subject)
      assert {:ok, [], _metadata} = list_flows_for(gateway, subject)
    end

    test "returns error when subject has no permission to view flows", %{
      client: client,
      actor: actor,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      expected_error =
        {:error,
         {:unauthorized,
          reason: :missing_permissions,
          missing_permissions: [Flows.Authorizer.manage_flows_permission()]}}

      assert list_flows_for(policy, subject) == expected_error
      assert list_flows_for(resource, subject) == expected_error
      assert list_flows_for(client, subject) == expected_error
      assert list_flows_for(actor, subject) == expected_error
      assert list_flows_for(gateway, subject) == expected_error
    end
  end

  describe "delete_flows_for/1" do
    setup %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      subject = %{subject | expires_at: DateTime.utc_now() |> DateTime.add(1, :day)}

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      %{flow: flow}
    end

    test "deletes flows for account", %{
      account: account
    } do
      assert {1, nil} = delete_flows_for(account)
    end

    test "deletes flows for membership", %{
      membership: membership
    } do
      assert {1, nil} = delete_flows_for(membership)
    end

    test "deletes flows for client", %{
      client: client
    } do
      assert {1, nil} = delete_flows_for(client)
    end

    test "deletes flows for gateway", %{
      gateway: gateway
    } do
      assert {1, nil} = delete_flows_for(gateway)
    end

    test "deletes flows for policy", %{
      policy: policy
    } do
      assert {1, nil} = delete_flows_for(policy)
    end

    test "deletes flows for resource", %{
      resource: resource
    } do
      assert {1, nil} = delete_flows_for(resource)
    end

    test "deletes flows for token", %{
      subject: subject
    } do
      {:ok, token} = Domain.Tokens.fetch_token_by_id(subject.token_id, subject)

      assert {1, nil} = delete_flows_for(token)
    end
  end

  describe "delete_expired_flows/0" do
    test "deletes only expired flows", %{account: account} do
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :day)
      flow1 = Fixtures.Flows.create_flow(account: account, expires_at: expired_at)

      not_expired_at = DateTime.utc_now() |> DateTime.add(1, :day)
      flow2 = Fixtures.Flows.create_flow(account: account, expires_at: not_expired_at)

      delete_expired_flows()

      assert Repo.get(Flows.Flow, flow1.id) == nil
      assert [^flow2] = Repo.all(Flows.Flow)
    end
  end

  describe "delete_stale_flows_on_connect/2" do
    setup %{
      account: account
    } do
      # Create additional resources for testing
      resource2 = Fixtures.Resources.create_resource(account: account)
      resource3 = Fixtures.Resources.create_resource(account: account)

      %{
        resource2: resource2,
        resource3: resource3
      }
    end

    test "deletes flows for resources not in authorized list", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      resource2: resource2,
      resource3: resource3,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      # Create flows for multiple resources
      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource2,
          gateway: gateway
        )

      flow3 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource3,
          gateway: gateway
        )

      # Only authorize resource1 and resource2, resource3 should be deleted
      authorized_resource_ids = [resource1.id, resource2.id]

      assert {1, nil} = delete_stale_flows_on_connect(client, authorized_resource_ids)

      # Verify flow3 was deleted but flow1 and flow2 remain
      assert {:ok, ^flow1} = fetch_flow_by_id(flow1.id, subject)
      assert {:ok, ^flow2} = fetch_flow_by_id(flow2.id, subject)
      assert {:error, :not_found} = fetch_flow_by_id(flow3.id, subject)
    end

    test "deletes no flows when all resources are authorized", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      resource2: resource2,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource2,
          gateway: gateway
        )

      # Authorize all resources
      authorized_resource_ids = [resource1.id, resource2.id]

      assert {0, nil} = delete_stale_flows_on_connect(client, authorized_resource_ids)

      # Verify both flows still exist
      assert {:ok, ^flow1} = fetch_flow_by_id(flow1.id, subject)
      assert {:ok, ^flow2} = fetch_flow_by_id(flow2.id, subject)
    end

    test "deletes all flows when authorized list is empty", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      resource2: resource2,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource2,
          gateway: gateway
        )

      # Empty authorized list - all flows should be deleted
      authorized_resource_ids = []

      assert {2, nil} = delete_stale_flows_on_connect(client, authorized_resource_ids)

      # Verify both flows were deleted
      assert {:error, :not_found} = fetch_flow_by_id(flow1.id, subject)
      assert {:error, :not_found} = fetch_flow_by_id(flow2.id, subject)
    end

    test "only affects flows for the specified client", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      resource2: resource2,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      # Create another client
      other_client = Fixtures.Clients.create_client(account: account)

      # Create flows for both clients with the same resources
      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: other_client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      # Only authorize resource2 for the first client (resource1 should be deleted)
      authorized_resource_ids = [resource2.id]

      assert {1, nil} = delete_stale_flows_on_connect(client, authorized_resource_ids)

      # Verify only the first client's flow was deleted
      assert {:error, :not_found} = fetch_flow_by_id(flow1.id, subject)
      assert {:ok, ^flow2} = fetch_flow_by_id(flow2.id, subject)
    end

    test "only affects flows for the specified account", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      # Create flows in the current account
      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      # Create flows in a different account
      Fixtures.Flows.create_flow()

      # Empty authorized list for current account
      authorized_resource_ids = []

      assert {1, nil} = delete_stale_flows_on_connect(client, authorized_resource_ids)

      # Verify only the current account's flow was deleted
      assert {:error, :not_found} = fetch_flow_by_id(flow1.id, subject)
      # We can't easily verify flow2 still exists since it's in another account,
      # but the fact that only 1 flow was deleted confirms account isolation
    end

    test "handles case when no flows exist for client", %{
      client: client
    } do
      # Try to delete stale flows for a client with no flows
      authorized_resource_ids = []

      assert {0, nil} = delete_stale_flows_on_connect(client, authorized_resource_ids)
    end

    test "handles case when client has no flows but resources are provided", %{
      account: account,
      resource: resource
    } do
      # Create a client with no flows
      client_with_no_flows = Fixtures.Clients.create_client(account: account)
      authorized_resource_ids = [resource.id]

      assert {0, nil} =
               delete_stale_flows_on_connect(client_with_no_flows, authorized_resource_ids)
    end
  end
end
