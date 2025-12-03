defmodule Domain.PolicyAuthorizationsTest do
  use Domain.DataCase, async: true
  import Domain.PolicyAuthorizations
  alias Domain.PolicyAuthorizations
  alias Domain.PolicyAuthorizations.Authorizer

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
        site_id: site.id
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

  describe "create_policy_authorization/7" do
    test "creates a new policy_authorization for users", %{
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

      assert {:ok, %PolicyAuthorizations.PolicyAuthorization{} = policy_authorization} =
               create_policy_authorization(
                 client,
                 gateway,
                 resource.id,
                 policy.id,
                 membership.id,
                 subject,
                 subject.expires_at
               )

      assert policy_authorization.policy_id == policy.id
      assert policy_authorization.client_id == client.id
      assert policy_authorization.gateway_id == gateway.id
      assert policy_authorization.resource_id == resource.id
      assert policy_authorization.account_id == account.id
      assert policy_authorization.client_remote_ip.address == subject.context.remote_ip
      assert policy_authorization.client_user_agent == subject.context.user_agent
      assert policy_authorization.gateway_remote_ip == gateway.last_seen_remote_ip
      assert policy_authorization.membership_id == membership.id
      assert policy_authorization.expires_at == subject.expires_at
    end

    test "creates a new policy_authorization for service accounts", %{
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

      assert {:ok, %PolicyAuthorizations.PolicyAuthorization{} = policy_authorization} =
               create_policy_authorization(
                 client,
                 gateway,
                 resource.id,
                 policy.id,
                 membership.id,
                 subject,
                 subject.expires_at
               )

      assert policy_authorization.policy_id == policy.id
      assert policy_authorization.client_id == client.id
      assert policy_authorization.gateway_id == gateway.id
      assert policy_authorization.resource_id == resource.id
      assert policy_authorization.account_id == account.id
      assert policy_authorization.client_remote_ip.address == subject.context.remote_ip
      assert policy_authorization.client_user_agent == subject.context.user_agent
      assert policy_authorization.gateway_remote_ip == gateway.last_seen_remote_ip
      assert policy_authorization.membership_id == membership.id
      assert policy_authorization.expires_at == subject.expires_at
    end
  end

  describe "reauthorize_policy_authorization/1" do
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

      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
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

      assert {:ok, reauthorized_policy_authorization} =
               reauthorize_policy_authorization(policy_authorization)

      assert reauthorized_policy_authorization.resource_id == policy_authorization.resource_id
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
      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
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

      assert :error = reauthorize_policy_authorization(policy_authorization)
    end
  end

  describe "fetch_policy_authorization_by_id/3" do
    test "returns error when policy_authorization does not exist", %{subject: subject} do
      assert fetch_policy_authorization_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_policy_authorization_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns policy_authorization", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert {:ok, fetched_policy_authorization} =
               fetch_policy_authorization_by_id(policy_authorization.id, subject)

      assert fetched_policy_authorization.id == policy_authorization.id
    end

    test "does not return policy_authorizations in other accounts", %{subject: subject} do
      policy_authorization = Fixtures.PolicyAuthorizations.create_policy_authorization()

      assert fetch_policy_authorization_by_id(policy_authorization.id, subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view policy_authorizations", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_policy_authorization_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_policy_authorizations_permission()]}}
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
      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert {:ok, policy_authorization} =
               fetch_policy_authorization_by_id(policy_authorization.id, subject,
                 preload: [
                   :policy,
                   :client,
                   :gateway,
                   :resource,
                   :account
                 ]
               )

      assert Ecto.assoc_loaded?(policy_authorization.policy)
      assert Ecto.assoc_loaded?(policy_authorization.client)
      assert Ecto.assoc_loaded?(policy_authorization.gateway)
      assert Ecto.assoc_loaded?(policy_authorization.resource)
      assert Ecto.assoc_loaded?(policy_authorization.account)
    end
  end

  describe "all_gateway_policy_authorizations_for_cache!/1" do
    test "returns all policy_authorizations for client_id/resource_id pair", %{
      account: account,
      client: client,
      gateway: gateway,
      membership: membership,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      policy_authorization2 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert policy_authorization1.client_id == policy_authorization2.client_id
      assert policy_authorization1.resource_id == policy_authorization2.resource_id

      assert DateTime.compare(
               policy_authorization2.inserted_at,
               policy_authorization1.inserted_at
             ) == :gt

      policy_authorizations = all_gateway_policy_authorizations_for_cache!(gateway)

      assert {{policy_authorization1.client_id, policy_authorization1.resource_id},
              {policy_authorization1.id, policy_authorization1.expires_at}} in policy_authorizations

      assert {{policy_authorization2.client_id, policy_authorization2.resource_id},
              {policy_authorization2.id, policy_authorization2.expires_at}} in policy_authorizations
    end
  end

  describe "list_policy_authorizations_for/3" do
    test "returns empty list when there are no policy_authorizations", %{
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      assert {:ok, [], _metadata} = list_policy_authorizations_for(policy, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(resource, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(actor, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(client, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(gateway, subject)
    end

    test "does not list policy_authorizations from other accounts", %{
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      Fixtures.PolicyAuthorizations.create_policy_authorization()

      assert {:ok, [], _metadata} = list_policy_authorizations_for(policy, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(resource, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(actor, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(client, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(gateway, subject)
    end

    test "returns all authorized policy_authorizations for a given entity", %{
      account: account,
      actor: actor,
      client: client,
      gateway: gateway,
      membership: membership,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      assert {:ok, [^policy_authorization], _metadata} =
               list_policy_authorizations_for(policy, subject)

      assert {:ok, [^policy_authorization], _metadata} =
               list_policy_authorizations_for(resource, subject)

      assert {:ok, [^policy_authorization], _metadata} =
               list_policy_authorizations_for(actor, subject)

      assert {:ok, [^policy_authorization], _metadata} =
               list_policy_authorizations_for(client, subject)

      assert {:ok, [^policy_authorization], _metadata} =
               list_policy_authorizations_for(gateway, subject)
    end

    test "does not return authorized policy_authorization of other entities", %{
      account: account,
      actor: actor,
      client: client,
      gateway: gateway,
      resource: resource,
      policy: policy,
      subject: subject
    } do
      other_client = Fixtures.Clients.create_client(account: account)

      Fixtures.PolicyAuthorizations.create_policy_authorization(
        account: account,
        client: other_client,
        subject: subject
      )

      assert {:ok, [], _metadata} = list_policy_authorizations_for(policy, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(resource, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(actor, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(client, subject)
      assert {:ok, [], _metadata} = list_policy_authorizations_for(gateway, subject)
    end

    test "returns error when subject has no permission to view policy_authorizations", %{
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
          missing_permissions: [
            PolicyAuthorizations.Authorizer.manage_policy_authorizations_permission()
          ]}}

      assert list_policy_authorizations_for(policy, subject) == expected_error
      assert list_policy_authorizations_for(resource, subject) == expected_error
      assert list_policy_authorizations_for(client, subject) == expected_error
      assert list_policy_authorizations_for(actor, subject) == expected_error
      assert list_policy_authorizations_for(gateway, subject) == expected_error
    end
  end

  describe "delete_policy_authorizations_for/1" do
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

      policy_authorization =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource,
          gateway: gateway
        )

      %{policy_authorization: policy_authorization}
    end

    test "deletes policy_authorizations for account", %{
      account: account
    } do
      assert {1, nil} = delete_policy_authorizations_for(account)
    end

    test "deletes policy_authorizations for membership", %{
      membership: membership
    } do
      assert {1, nil} = delete_policy_authorizations_for(membership)
    end

    test "deletes policy_authorizations for client", %{
      client: client
    } do
      assert {1, nil} = delete_policy_authorizations_for(client)
    end

    test "deletes policy_authorizations for gateway", %{
      gateway: gateway
    } do
      assert {1, nil} = delete_policy_authorizations_for(gateway)
    end

    test "deletes policy_authorizations for policy", %{
      policy: policy
    } do
      assert {1, nil} = delete_policy_authorizations_for(policy)
    end

    test "deletes policy_authorizations for resource", %{
      resource: resource
    } do
      assert {1, nil} = delete_policy_authorizations_for(resource)
    end

    test "deletes policy_authorizations for token", %{
      subject: subject
    } do
      {:ok, token} = Domain.Tokens.fetch_token_by_id(subject.token_id, subject)

      assert {1, nil} = delete_policy_authorizations_for(token)
    end
  end

  describe "delete_expired_policy_authorizations/0" do
    test "deletes only expired policy_authorizations", %{account: account} do
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :day)

      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          expires_at: expired_at
        )

      not_expired_at = DateTime.utc_now() |> DateTime.add(1, :day)

      policy_authorization2 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          expires_at: not_expired_at
        )

      delete_expired_policy_authorizations()

      assert Repo.get(PolicyAuthorizations.PolicyAuthorization, policy_authorization1.id) == nil
      assert [^policy_authorization2] = Repo.all(PolicyAuthorizations.PolicyAuthorization)
    end
  end

  describe "delete_stale_policy_authorizations_on_connect/2" do
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

    test "deletes policy_authorizations for resources not in authorized list", %{
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
      # Create policy_authorizations for multiple resources
      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      policy_authorization2 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource2,
          gateway: gateway
        )

      policy_authorization3 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
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

      assert {1, nil} =
               delete_stale_policy_authorizations_on_connect(client, authorized_resource_ids)

      # Verify policy_authorization3 was deleted but policy_authorization1 and policy_authorization2 remain
      assert {:ok, ^policy_authorization1} =
               fetch_policy_authorization_by_id(policy_authorization1.id, subject)

      assert {:ok, ^policy_authorization2} =
               fetch_policy_authorization_by_id(policy_authorization2.id, subject)

      assert {:error, :not_found} =
               fetch_policy_authorization_by_id(policy_authorization3.id, subject)
    end

    test "deletes no policy_authorizations when all resources are authorized", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      resource2: resource2,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      policy_authorization2 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
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

      assert {0, nil} =
               delete_stale_policy_authorizations_on_connect(client, authorized_resource_ids)

      # Verify both policy_authorizations still exist
      assert {:ok, ^policy_authorization1} =
               fetch_policy_authorization_by_id(policy_authorization1.id, subject)

      assert {:ok, ^policy_authorization2} =
               fetch_policy_authorization_by_id(policy_authorization2.id, subject)
    end

    test "deletes all policy_authorizations when authorized list is empty", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      resource2: resource2,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      policy_authorization2 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource2,
          gateway: gateway
        )

      # Empty authorized list - all policy_authorizations should be deleted
      authorized_resource_ids = []

      assert {2, nil} =
               delete_stale_policy_authorizations_on_connect(client, authorized_resource_ids)

      # Verify both policy_authorizations were deleted
      assert {:error, :not_found} =
               fetch_policy_authorization_by_id(policy_authorization1.id, subject)

      assert {:error, :not_found} =
               fetch_policy_authorization_by_id(policy_authorization2.id, subject)
    end

    test "only affects policy_authorizations for the specified client", %{
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

      # Create policy_authorizations for both clients with the same resources
      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      policy_authorization2 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
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

      assert {1, nil} =
               delete_stale_policy_authorizations_on_connect(client, authorized_resource_ids)

      # Verify only the first client's policy_authorization was deleted
      assert {:error, :not_found} =
               fetch_policy_authorization_by_id(policy_authorization1.id, subject)

      assert {:ok, ^policy_authorization2} =
               fetch_policy_authorization_by_id(policy_authorization2.id, subject)
    end

    test "only affects policy_authorizations for the specified account", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource1,
      membership: membership,
      policy: policy,
      subject: subject
    } do
      # Create policy_authorizations in the current account
      policy_authorization1 =
        Fixtures.PolicyAuthorizations.create_policy_authorization(
          account: account,
          subject: subject,
          client: client,
          membership: membership,
          policy: policy,
          resource: resource1,
          gateway: gateway
        )

      # Create policy_authorizations in a different account
      Fixtures.PolicyAuthorizations.create_policy_authorization()

      # Empty authorized list for current account
      authorized_resource_ids = []

      assert {1, nil} =
               delete_stale_policy_authorizations_on_connect(client, authorized_resource_ids)

      # Verify only the current account's policy_authorization was deleted
      assert {:error, :not_found} =
               fetch_policy_authorization_by_id(policy_authorization1.id, subject)

      # We can't easily verify policy_authorization2 still exists since it's in another account,
      # but the fact that only 1 policy_authorization was deleted confirms account isolation
    end

    test "handles case when no policy_authorizations exist for client", %{
      client: client
    } do
      # Try to delete stale policy_authorizations for a client with no policy_authorizations
      authorized_resource_ids = []

      assert {0, nil} =
               delete_stale_policy_authorizations_on_connect(client, authorized_resource_ids)
    end

    test "handles case when client has no policy_authorizations but resources are provided", %{
      account: account,
      resource: resource
    } do
      # Create a client with no policy_authorizations
      client_with_no_policy_authorizations = Fixtures.Clients.create_client(account: account)
      authorized_resource_ids = [resource.id]

      assert {0, nil} =
               delete_stale_policy_authorizations_on_connect(
                 client_with_no_policy_authorizations,
                 authorized_resource_ids
               )
    end
  end
end
