defmodule Domain.FlowsTest do
  use Domain.DataCase, async: true
  import Domain.Flows
  alias Domain.Flows
  alias Domain.Flows.Authorizer

  setup do
    account = Fixtures.Accounts.create_account()

    actor_group = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    provider = Fixtures.Auth.create_email_provider(account: account)

    identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
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
      provider: provider,
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
      assert {:ok, fetched_resource, _flow, _expires_at} =
               authorize_flow(client, gateway, resource.id, subject)

      assert fetched_resource.id == resource.id
      assert hd(fetched_resource.authorized_by_policies).id == policy.id
    end

    test "returns error when some conditions are not satisfied", %{
      account: account,
      actor_group: actor_group,
      client: client,
      gateway_group: gateway_group,
      gateway: gateway,
      subject: subject
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["AU"]
          },
          %{
            property: :remote_ip_location_region,
            operator: :is_not_in,
            values: [client.last_seen_remote_ip_location_region]
          },
          %{
            property: :remote_ip,
            operator: :is_in_cidr,
            values: ["0.0.0.0/0", "0::/0"]
          }
        ]
      )

      assert authorize_flow(client, gateway, resource.id, subject) ==
               {:error, {:forbidden, violated_properties: [:remote_ip_location_region]}}
    end

    test "returns error when all conditions are not satisfied", %{
      account: account,
      actor_group: actor_group,
      client: client,
      gateway_group: gateway_group,
      gateway: gateway,
      subject: subject
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["AU"]
          },
          %{
            property: :remote_ip_location_region,
            operator: :is_not_in,
            values: [client.last_seen_remote_ip_location_region]
          }
        ]
      )

      assert authorize_flow(client, gateway, resource.id, subject) ==
               {:error, {:forbidden, violated_properties: [:remote_ip_location_region]}}
    end

    test "creates a flow when the only policy conditions are satisfied", %{
      account: account,
      actor: actor,
      resource: resource,
      client: client,
      policy: policy,
      gateway: gateway,
      subject: subject
    } do
      actor_group2 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group2)

      time = Time.utc_now()
      midnight = Time.from_iso8601!("23:59:59.999999")

      date = Date.utc_today()
      day_of_week = Enum.at(~w[M T W R F S U], Date.day_of_week(date) - 1)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group2,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_not_in,
            values: [client.last_seen_remote_ip_location_region]
          },
          %{
            property: :current_utc_datetime,
            operator: :is_in_day_of_week_time_ranges,
            values: [
              "#{day_of_week}/#{time}-#{midnight}/UTC"
            ]
          }
        ]
      )

      assert {:ok, _fetched_resource, flow, expires_at} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert DateTime.diff(expires_at, DateTime.new!(date, midnight)) < 5
    end

    test "creates a flow when all conditions for at least one of the policies are satisfied", %{
      account: account,
      actor_group: actor_group,
      client: client,
      gateway_group: gateway_group,
      gateway: gateway,
      subject: subject
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: [client.last_seen_remote_ip_location_region]
          },
          %{
            property: :remote_ip,
            operator: :is_in_cidr,
            values: ["0.0.0.0/0", "0::/0"]
          }
        ]
      )

      assert {:ok, _fetched_resource, flow, expires_at} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.resource_id == resource.id
      assert expires_at == subject.expires_at
    end

    test "creates a network flow for users", %{
      account: account,
      gateway: gateway,
      resource: resource,
      policy: policy,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)

      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      assert {:ok, _fetched_resource, %Flows.Flow{} = flow, expires_at} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.client_remote_ip.address == subject.context.remote_ip
      assert flow.client_user_agent == subject.context.user_agent
      assert flow.gateway_remote_ip == gateway.last_seen_remote_ip
      assert expires_at == subject.expires_at
    end

    test "creates a network flow for service accounts", %{
      account: account,
      actor_group: actor_group,
      gateway: gateway,
      resource: resource,
      policy: policy
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

      assert {:ok, _fetched_resource, %Flows.Flow{} = flow, expires_at} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.client_remote_ip.address == subject.context.remote_ip
      assert flow.client_user_agent == subject.context.user_agent
      assert flow.gateway_remote_ip == gateway.last_seen_remote_ip
      assert expires_at == subject.expires_at
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

    test "returns error on account_id mismatch", %{
      client: client,
      gateway: gateway,
      resource: resource,
      subject: subject
    } do
      other_subject = Fixtures.Auth.create_subject()
      other_client = Fixtures.Clients.create_client()
      other_gateway = Fixtures.Gateways.create_gateway()

      assert_raise FunctionClauseError, fn ->
        assert authorize_flow(client, gateway, resource.id, other_subject)
      end

      assert_raise FunctionClauseError, fn ->
        assert authorize_flow(client, other_gateway, resource.id, subject)
      end

      assert_raise FunctionClauseError, fn ->
        assert authorize_flow(other_client, gateway, resource.id, subject)
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
                 reason: :missing_permissions,
                 missing_permissions: [
                   Flows.Authorizer.create_flows_permission()
                 ]}}

      subject = Fixtures.Auth.add_permission(subject, Flows.Authorizer.create_flows_permission())

      assert authorize_flow(client, gateway, resource.id, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   Domain.Resources.Authorizer.view_available_resources_permission()
                 ]}}
    end

    test "preloads assocs", %{
      client: client,
      gateway: gateway,
      resource: resource,
      subject: subject
    } do
      assert {:ok, resource, _flow, _expires_at} =
               authorize_flow(client, gateway, resource.id, subject, preload: :connections)

      assert Ecto.assoc_loaded?(resource.connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert length(resource.connections) == 1
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

  describe "expire_flows_for/1" do
    setup %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      subject = %{subject | expires_at: DateTime.utc_now() |> DateTime.add(1, :day)}

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      %{flow: flow}
    end

    test "expires flows for policy actor group", %{
      flow: flow,
      actor_group: actor_group
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(actor_group)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for client identity", %{
      flow: flow,
      identity: identity
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(identity)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for client", %{
      flow: flow,
      client: client
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(client)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end
  end

  describe "expire_flows_for/2" do
    setup %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      subject = %{subject | expires_at: DateTime.utc_now() |> DateTime.add(1, :day)}

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      %{flow: flow}
    end

    test "expires flows for actor id and policy actor group id", %{
      flow: flow,
      actor: actor,
      policy: policy
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id

      assert :ok = expire_flows_for(actor.account_id, actor.id, policy.actor_group_id)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for actor", %{
      flow: flow,
      actor: actor,
      subject: subject
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(actor, subject)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for policy", %{
      flow: flow,
      policy: policy
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for_policy_id(policy.account_id, policy.id)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for resource", %{
      flow: flow,
      resource: resource,
      subject: subject
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(resource, subject)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for policy actor group", %{
      flow: flow,
      actor_group: actor_group,
      subject: subject
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(actor_group, subject)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for client identity", %{
      flow: flow,
      identity: identity,
      subject: subject
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(identity, subject)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "expires flows for client identity provider", %{
      flow: flow,
      provider: provider,
      subject: subject
    } do
      :ok = Domain.PubSub.Flow.subscribe(flow.id)
      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id
      assert :ok = expire_flows_for(provider, subject)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "returns error when subject has no permission to expire flows", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert expire_flows_for(resource, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.create_flows_permission()]}}
    end

    test "does not do anything on state conflict", %{
      resource: resource,
      actor_group: actor_group,
      subject: subject
    } do
      assert :ok = expire_flows_for(resource, subject)
      assert :ok = expire_flows_for(actor_group, subject)
      assert :ok = expire_flows_for(resource, subject)
    end

    test "does not expire flows outside of account", %{
      resource: resource
    } do
      subject = Fixtures.Auth.create_subject()
      assert :ok = expire_flows_for(resource, subject)
    end
  end
end
