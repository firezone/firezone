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
      assert {:ok, fetched_resource, _flow} =
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

      assert {:ok, _fetched_resource, flow} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert DateTime.diff(flow.expires_at, DateTime.new!(date, midnight)) < 5
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

      assert {:ok, _fetched_resource, flow} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.expires_at == subject.expires_at
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

      assert {:ok, _fetched_resource, %Flows.Flow{} = flow} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.client_remote_ip.address == subject.context.remote_ip
      assert flow.client_user_agent == subject.context.user_agent
      assert flow.gateway_remote_ip == gateway.last_seen_remote_ip
      assert flow.expires_at == subject.expires_at
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

      assert {:ok, _fetched_resource, %Flows.Flow{} = flow} =
               authorize_flow(client, gateway, resource.id, subject)

      assert flow.policy_id == policy.id
      assert flow.client_id == client.id
      assert flow.gateway_id == gateway.id
      assert flow.resource_id == resource.id
      assert flow.account_id == account.id
      assert flow.client_remote_ip.address == subject.context.remote_ip
      assert flow.client_user_agent == subject.context.user_agent
      assert flow.gateway_remote_ip == gateway.last_seen_remote_ip
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
      assert {:ok, resource, _flow} =
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

  describe "upsert_activities/1" do
    test "inserts new activities", %{
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

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, destination} = Domain.Types.ProtocolIPPort.cast("tcp://127.0.0.1:80")

      activity = %{
        window_started_at: DateTime.add(now, -1, :minute),
        window_ended_at: now,
        destination: destination,
        rx_bytes: 100,
        tx_bytes: 200,
        blocked_tx_bytes: 0,
        connectivity_type: :direct,
        flow_id: flow.id,
        account_id: account.id
      }

      assert upsert_activities([activity]) == {:ok, 1}

      assert upserted_activity = Repo.one(Flows.Activity)
      assert upserted_activity.window_started_at == activity.window_started_at
      assert upserted_activity.window_ended_at == activity.window_ended_at
      assert upserted_activity.destination == destination
      assert upserted_activity.rx_bytes == activity.rx_bytes
      assert upserted_activity.tx_bytes == activity.tx_bytes
      assert upserted_activity.flow_id == flow.id
      assert upserted_activity.account_id == account.id
    end

    test "ignores upsert conflicts", %{
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

      activity = Fixtures.Flows.activity_attrs(flow_id: flow.id, account_id: account.id)

      assert upsert_activities([activity]) == {:ok, 1}
      assert upsert_activities([activity]) == {:ok, 0}

      assert Repo.one(Flows.Activity)
    end
  end

  describe "fetch_last_activity_for/3" do
    setup %{
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

      %{flow: flow}
    end

    test "returns error when flow has no activities", %{subject: subject, flow: flow} do
      assert fetch_last_activity_for(flow, subject) == {:error, :not_found}
    end

    test "returns last activity for a flow", %{subject: subject, flow: flow} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      thirty_minutes_ago = DateTime.add(now, -30, :minute)
      five_minutes_ago = DateTime.add(now, -5, :minute)
      four_minutes_ago = DateTime.add(now, -4, :minute)

      Fixtures.Flows.create_activity(
        flow: flow,
        window_started_at: thirty_minutes_ago,
        window_ended_at: five_minutes_ago
      )

      activity =
        Fixtures.Flows.create_activity(
          flow: flow,
          window_started_at: five_minutes_ago,
          window_ended_at: four_minutes_ago
        )

      assert {:ok, fetched_activity} = fetch_last_activity_for(flow, subject)
      assert fetched_activity.id == activity.id
    end

    test "returns error when subject has no permission to view flows", %{
      flow: flow,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_last_activity_for(flow, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Flows.Authorizer.manage_flows_permission()]}}
    end
  end

  describe "list_flow_activities_for/4" do
    setup %{
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

      %{flow: flow}
    end

    test "returns empty list when there are no flow activities", %{
      account: account,
      flow: flow,
      subject: subject
    } do
      assert {:ok, [], _metadata} =
               list_flow_activities_for(account, subject)

      assert {:ok, [], _metadata} =
               list_flow_activities_for(flow, subject)
    end

    test "does not list flow activities from other accounts", %{
      account: account,
      subject: subject
    } do
      flow = Fixtures.Flows.create_flow()
      Fixtures.Flows.create_activity(flow: flow)

      assert {:ok, [], _metadata} =
               list_flow_activities_for(account, subject)

      assert {:ok, [], _metadata} =
               list_flow_activities_for(flow, subject)
    end

    test "returns ordered by window start time flow activities within a time window", %{
      account: account,
      flow: flow,
      subject: subject
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      thirty_minutes_ago = DateTime.add(now, -30, :minute)
      five_minutes_ago = DateTime.add(now, -5, :minute)
      four_minutes_ago = DateTime.add(now, -4, :minute)
      three_minutes_ago = DateTime.add(now, -4, :minute)
      thirty_minutes_in_future = DateTime.add(now, 30, :minute)
      sixty_minutes_in_future = DateTime.add(now, 60, :minute)

      activity1 =
        Fixtures.Flows.create_activity(
          flow: flow,
          window_started_at: four_minutes_ago,
          window_ended_at: three_minutes_ago
        )

      assert {:ok, [], _metadata} =
               list_flow_activities_for(
                 account,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: thirty_minutes_in_future,
                     to: sixty_minutes_in_future
                   }
                 ]
               )

      assert {:ok, [], _metadata} =
               list_flow_activities_for(
                 flow,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: thirty_minutes_in_future,
                     to: sixty_minutes_in_future
                   }
                 ]
               )

      assert {:ok, [], _metadata} =
               list_flow_activities_for(
                 account,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: thirty_minutes_ago,
                     to: five_minutes_ago
                   }
                 ]
               )

      assert {:ok, [], _metadata} =
               list_flow_activities_for(
                 flow,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: thirty_minutes_ago,
                     to: five_minutes_ago
                   }
                 ]
               )

      assert {:ok, [^activity1], _metadata} =
               list_flow_activities_for(
                 account,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: five_minutes_ago,
                     to: now
                   }
                 ]
               )

      assert {:ok, [^activity1], _metadata} =
               list_flow_activities_for(
                 flow,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: five_minutes_ago,
                     to: now
                   }
                 ]
               )

      activity2 =
        Fixtures.Flows.create_activity(
          flow: flow,
          window_started_at: five_minutes_ago,
          window_ended_at: four_minutes_ago
        )

      assert {:ok, [^activity2, ^activity1], _metadata} =
               list_flow_activities_for(
                 account,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: thirty_minutes_ago,
                     to: now
                   }
                 ]
               )

      assert {:ok, [^activity2, ^activity1], _metadata} =
               list_flow_activities_for(
                 flow,
                 subject,
                 filter: [
                   window_within: %Domain.Repo.Filter.Range{
                     from: thirty_minutes_ago,
                     to: now
                   }
                 ]
               )
    end

    test "returns error when subject has no permission to view flows", %{
      account: account,
      flow: flow,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_flow_activities_for(account, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Flows.Authorizer.manage_flows_permission()]}}

      assert list_flow_activities_for(flow, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Flows.Authorizer.manage_flows_permission()]}}
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
      assert {:ok, [expired_flow]} = expire_flows_for(actor_group)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for client identity", %{
      flow: flow,
      identity: identity
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(identity)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for client", %{
      flow: flow,
      client: client
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(client)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
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
      assert {:ok, [expired_flow]} = expire_flows_for(actor.id, policy.actor_group_id)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for actor", %{
      flow: flow,
      actor: actor,
      subject: subject
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(actor, subject)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for policy", %{
      flow: flow,
      policy: policy
    } do
      assert {:ok, [expired_flow]} = expire_flows_for_policy_id(policy.id)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for resource", %{
      flow: flow,
      resource: resource,
      subject: subject
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(resource, subject)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for policy actor group", %{
      flow: flow,
      actor_group: actor_group,
      subject: subject
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(actor_group, subject)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for client identity", %{
      flow: flow,
      identity: identity,
      subject: subject
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(identity, subject)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "expires flows for client identity provider", %{
      flow: flow,
      provider: provider,
      subject: subject
    } do
      assert {:ok, [expired_flow]} = expire_flows_for(provider, subject)
      assert DateTime.diff(expired_flow.expires_at, DateTime.utc_now()) <= 1
      assert expired_flow.id == flow.id
    end

    test "updates flow expiration expires_at", %{
      flow: flow,
      actor: actor,
      subject: subject
    } do
      assert {:ok, [_expired_flow]} = expire_flows_for(actor, subject)

      flow = Repo.reload(flow)
      assert DateTime.compare(flow.expires_at, DateTime.utc_now()) == :lt
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
      assert {:ok, [_expired_flow]} = expire_flows_for(resource, subject)
      assert {:ok, []} = expire_flows_for(actor_group, subject)
      assert {:ok, []} = expire_flows_for(resource, subject)
    end

    test "does not expire flows outside of account", %{
      resource: resource
    } do
      subject = Fixtures.Auth.create_subject()
      assert {:ok, []} = expire_flows_for(resource, subject)
    end
  end
end
