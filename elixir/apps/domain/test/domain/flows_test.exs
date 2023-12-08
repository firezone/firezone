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

      assert Ecto.assoc_loaded?(resource.connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert Ecto.assoc_loaded?(resource.connections)
      assert length(resource.connections) == 1
    end
  end

  describe "fetch_flow_by_id/2" do
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
                {:unauthorized, [missing_permissions: [Authorizer.view_flows_permission()]]}}
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

  describe "list_flows_for/2" do
    test "returns empty list when there are no flows", %{
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      assert list_flows_for(policy, subject) == {:ok, []}
      assert list_flows_for(resource, subject) == {:ok, []}
      assert list_flows_for(actor, subject) == {:ok, []}
      assert list_flows_for(client, subject) == {:ok, []}
      assert list_flows_for(gateway, subject) == {:ok, []}
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

      assert list_flows_for(policy, subject) == {:ok, []}
      assert list_flows_for(resource, subject) == {:ok, []}
      assert list_flows_for(actor, subject) == {:ok, []}
      assert list_flows_for(client, subject) == {:ok, []}
      assert list_flows_for(gateway, subject) == {:ok, []}
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

      assert list_flows_for(policy, subject) == {:ok, [flow]}
      assert list_flows_for(resource, subject) == {:ok, [flow]}
      assert list_flows_for(actor, subject) == {:ok, [flow]}
      assert list_flows_for(client, subject) == {:ok, [flow]}
      assert list_flows_for(gateway, subject) == {:ok, [flow]}
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

      assert list_flows_for(policy, subject) == {:ok, []}
      assert list_flows_for(resource, subject) == {:ok, []}
      assert list_flows_for(actor, subject) == {:ok, []}
      assert list_flows_for(client, subject) == {:ok, []}
      assert list_flows_for(gateway, subject) == {:ok, []}
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
         {:unauthorized, [missing_permissions: [Flows.Authorizer.view_flows_permission()]]}}

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

      {:ok, destination} = Domain.Types.IPPort.cast("127.0.0.1:80")

      activity = %{
        window_started_at: DateTime.add(now, -1, :minute),
        window_ended_at: now,
        destination: destination,
        rx_bytes: 100,
        tx_bytes: 200,
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
      now = DateTime.utc_now()
      ended_after = DateTime.add(now, -30, :minute)
      started_before = DateTime.add(now, 30, :minute)

      assert list_flow_activities_for(account, ended_after, started_before, subject) == {:ok, []}
      assert list_flow_activities_for(flow, ended_after, started_before, subject) == {:ok, []}
    end

    test "does not list flow activities from other accounts", %{
      account: account,
      subject: subject
    } do
      flow = Fixtures.Flows.create_flow()
      Fixtures.Flows.create_activity(flow: flow)

      now = DateTime.utc_now()
      ended_after = DateTime.add(now, -30, :minute)
      started_before = DateTime.add(now, 30, :minute)

      assert list_flow_activities_for(account, ended_after, started_before, subject) == {:ok, []}
      assert list_flow_activities_for(flow, ended_after, started_before, subject) == {:ok, []}
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

      assert list_flow_activities_for(
               account,
               thirty_minutes_in_future,
               sixty_minutes_in_future,
               subject
             ) == {:ok, []}

      assert list_flow_activities_for(
               flow,
               thirty_minutes_in_future,
               sixty_minutes_in_future,
               subject
             ) == {:ok, []}

      assert list_flow_activities_for(
               account,
               thirty_minutes_ago,
               five_minutes_ago,
               subject
             ) == {:ok, []}

      assert list_flow_activities_for(
               flow,
               thirty_minutes_ago,
               five_minutes_ago,
               subject
             ) == {:ok, []}

      assert list_flow_activities_for(
               account,
               five_minutes_ago,
               now,
               subject
             ) == {:ok, [activity1]}

      assert list_flow_activities_for(
               flow,
               five_minutes_ago,
               now,
               subject
             ) == {:ok, [activity1]}

      activity2 =
        Fixtures.Flows.create_activity(
          flow: flow,
          window_started_at: five_minutes_ago,
          window_ended_at: four_minutes_ago
        )

      assert list_flow_activities_for(
               account,
               thirty_minutes_ago,
               now,
               subject
             ) == {:ok, [activity2, activity1]}

      assert list_flow_activities_for(
               flow,
               thirty_minutes_ago,
               now,
               subject
             ) == {:ok, [activity2, activity1]}
    end

    test "returns error when subject has no permission to view flows", %{
      account: account,
      flow: flow,
      subject: subject
    } do
      now = DateTime.utc_now()
      ended_after = DateTime.add(now, -30, :minute)
      started_before = DateTime.add(now, 30, :minute)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_flow_activities_for(account, ended_after, started_before, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Flows.Authorizer.view_flows_permission()]]}}

      assert list_flow_activities_for(flow, ended_after, started_before, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Flows.Authorizer.view_flows_permission()]]}}
    end
  end
end
