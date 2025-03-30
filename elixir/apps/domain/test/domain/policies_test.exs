defmodule Domain.PoliciesTest do
  use Domain.DataCase, async: true
  import Domain.Policies
  alias Domain.Policies

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

  describe "fetch_policy_by_id/3" do
    test "returns error when policy does not exist", %{subject: subject} do
      assert fetch_policy_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_policy_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns policy when policy exists", %{account: account, subject: subject} do
      policy = Fixtures.Policies.create_policy(account: account)

      assert {:ok, fetched_policy} = fetch_policy_by_id(policy.id, subject)
      assert fetched_policy.id == policy.id
    end

    test "returns deleted policies", %{account: account, subject: subject} do
      {:ok, policy} =
        Fixtures.Policies.create_policy(account: account)
        |> delete_policy(subject)

      assert {:ok, fetched_policy} = fetch_policy_by_id(policy.id, subject)
      assert fetched_policy.id == policy.id
    end

    test "does not return policies in other accounts", %{subject: subject} do
      policy = Fixtures.Policies.create_policy()
      assert fetch_policy_by_id(policy.id, subject) == {:error, :not_found}
    end

    test "returns error when subject has no permission to view policies", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_policy_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Policies.Authorizer.manage_policies_permission(),
                      Policies.Authorizer.view_available_policies_permission()
                    ]}
                 ]}}
    end

    # TODO: add a test that soft-deleted assocs are not preloaded
    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      policy = Fixtures.Policies.create_policy(account: account)
      {:ok, policy} = fetch_policy_by_id(policy.id, subject, preload: [:actor_group, :resource])

      assert Ecto.assoc_loaded?(policy.actor_group)
      assert Ecto.assoc_loaded?(policy.resource)
    end
  end

  describe "fetch_policy_by_id_or_persistent_id/3" do
    test "returns error when policy does not exist", %{subject: subject} do
      assert fetch_policy_by_id_or_persistent_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_policy_by_id_or_persistent_id("foo", subject) == {:error, :not_found}
    end

    test "returns policy when policy exists", %{account: account, subject: subject} do
      policy = Fixtures.Policies.create_policy(account: account)

      assert {:ok, fetched_policy} = fetch_policy_by_id_or_persistent_id(policy.id, subject)
      assert fetched_policy.id == policy.id

      assert {:ok, fetched_policy} =
               fetch_policy_by_id_or_persistent_id(policy.persistent_id, subject)

      assert fetched_policy.id == policy.id
    end

    test "returns deleted policies", %{account: account, subject: subject} do
      {:ok, policy} =
        Fixtures.Policies.create_policy(account: account)
        |> delete_policy(subject)

      assert {:ok, fetched_policy} = fetch_policy_by_id_or_persistent_id(policy.id, subject)
      assert fetched_policy.id == policy.id

      assert {:ok, fetched_policy} =
               fetch_policy_by_id_or_persistent_id(policy.persistent_id, subject)

      assert fetched_policy.id == policy.id
    end

    test "does not return policies in other accounts", %{subject: subject} do
      policy = Fixtures.Policies.create_policy()
      assert fetch_policy_by_id_or_persistent_id(policy.id, subject) == {:error, :not_found}

      assert fetch_policy_by_id_or_persistent_id(policy.persistent_id, subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view policies", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_policy_by_id_or_persistent_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Policies.Authorizer.manage_policies_permission(),
                      Policies.Authorizer.view_available_policies_permission()
                    ]}
                 ]}}
    end

    # TODO: add a test that soft-deleted assocs are not preloaded
    test "associations are preloaded when opts given", %{account: account, subject: subject} do
      policy = Fixtures.Policies.create_policy(account: account)

      {:ok, policy} =
        fetch_policy_by_id_or_persistent_id(policy.id, subject,
          preload: [:actor_group, :resource]
        )

      assert Ecto.assoc_loaded?(policy.actor_group)
      assert Ecto.assoc_loaded?(policy.resource)

      {:ok, policy} =
        fetch_policy_by_id_or_persistent_id(policy.persistent_id, subject,
          preload: [:actor_group, :resource]
        )

      assert Ecto.assoc_loaded?(policy.actor_group)
      assert Ecto.assoc_loaded?(policy.resource)
    end
  end

  describe "list_policies/2" do
    test "returns empty list when there are no policies", %{subject: subject} do
      assert {:ok, [], _metadata} = list_policies(subject)
    end

    test "does not list policies from other accounts", %{subject: subject} do
      Fixtures.Policies.create_policy()
      assert {:ok, [], _metadata} = list_policies(subject)
    end

    test "does not list deleted policies", %{account: account, subject: subject} do
      Fixtures.Policies.create_policy(account: account)
      |> delete_policy(subject)

      assert {:ok, [], _metadata} = list_policies(subject)
    end

    test "returns all policies for account admin subject", %{account: account} do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      Fixtures.Policies.create_policy(account: account)
      Fixtures.Policies.create_policy(account: account)
      Fixtures.Policies.create_policy()

      assert {:ok, policies, _metadata} = list_policies(subject)
      assert length(policies) == 2
    end

    test "returns select policies for non-admin subject", %{account: account, subject: subject} do
      unprivileged_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

      unprivileged_subject =
        Fixtures.Auth.create_subject(account: account, actor: unprivileged_actor)

      actor_group = Fixtures.Actors.create_group(account: account, subject: subject)

      Fixtures.Actors.create_membership(
        account: account,
        actor: unprivileged_actor,
        group: actor_group
      )

      Fixtures.Policies.create_policy(account: account, actor_group: actor_group)
      Fixtures.Policies.create_policy(account: account)
      Fixtures.Policies.create_policy()

      assert {:ok, policies, _metadata} = list_policies(unprivileged_subject)
      assert length(policies) == 1
    end

    test "returns error when subject has no permission to view policies", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_policies(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Policies.Authorizer.manage_policies_permission(),
                      Policies.Authorizer.view_available_policies_permission()
                    ]}
                 ]}}
    end
  end

  describe "create_policy/2" do
    test "returns changeset error on empty params", %{subject: subject} do
      assert {:error, changeset} = create_policy(%{}, subject)

      assert errors_on(changeset) == %{
               actor_group_id: ["can't be blank"],
               resource_id: ["can't be blank"]
             }
    end

    test "returns changeset error on invalid params", %{subject: subject} do
      attrs = %{description: 1, actor_group_id: "foo", resource_id: "bar"}
      assert {:error, changeset} = create_policy(attrs, subject)
      assert errors_on(changeset) == %{description: ["is invalid"]}

      attrs = %{attrs | description: String.duplicate("a", 1025)}
      assert {:error, changeset} = create_policy(attrs, subject)
      assert "should be at most 1024 character(s)" in errors_on(changeset).description
    end

    test "returns error when subject has no permission to manage policies", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_policy(%{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of, [Policies.Authorizer.manage_policies_permission()]}
                 ]}}
    end

    test "returns error when trying to create policy with another account actor_group", %{
      account: account,
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()

      resource = Fixtures.Resources.create_resource(account: account)
      other_actor_group = Fixtures.Actors.create_group(account: other_account)

      attrs = %{
        description: "yikes",
        actor_group_id: other_actor_group.id,
        resource_id: resource.id
      }

      assert {:error, changeset} = create_policy(attrs, subject)

      assert errors_on(changeset) == %{actor_group: ["does not exist"]}
    end

    test "returns changeset error when trying to create policy with another account resource", %{
      account: account,
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()

      other_resource = Fixtures.Resources.create_resource(account: other_account)
      actor_group = Fixtures.Actors.create_group(account: account)

      attrs = %{
        description: "yikes",
        actor_group_id: actor_group.id,
        resource_id: other_resource.id
      }

      assert {:error, changeset} = create_policy(attrs, subject)

      assert errors_on(changeset) == %{resource: ["does not exist"]}
    end

    test "creates a policy", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      attrs = %{
        actor_group_id: actor_group.id,
        resource_id: resource.id
      }

      assert {:ok, policy} = create_policy(attrs, subject)
      assert policy.actor_group_id == actor_group.id
      assert policy.resource_id == resource.id
    end

    test "creates a policy with conditions", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      attrs = %{
        actor_group_id: actor_group.id,
        resource_id: resource.id,
        conditions: [
          %{
            property: :remote_ip,
            operator: :is_in_cidr,
            values: ["10.10.0.0/24"]
          },
          %{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["US"]
          },
          %{
            property: :provider_id,
            operator: :is_not_in,
            values: ["3c712b5d-b1af-4b5a-9f33-aa3d1a4dc296"]
          },
          %{
            property: :current_utc_datetime,
            operator: :is_in_day_of_week_time_ranges,
            values: [
              "M/13:00:00-15:00:00,19:00:00-22:00:00/Poland",
              "F/08:00:00-20:00:00/UTC",
              "S/true/US/Pacific"
            ]
          }
        ]
      }

      assert {:ok, policy} = create_policy(attrs, subject)

      assert policy.conditions == [
               %Policies.Condition{
                 property: :remote_ip,
                 operator: :is_in_cidr,
                 values: ["10.10.0.0/24"]
               },
               %Policies.Condition{
                 property: :remote_ip_location_region,
                 operator: :is_in,
                 values: ["US"]
               },
               %Policies.Condition{
                 property: :provider_id,
                 operator: :is_not_in,
                 values: ["3c712b5d-b1af-4b5a-9f33-aa3d1a4dc296"]
               },
               %Policies.Condition{
                 property: :current_utc_datetime,
                 operator: :is_in_day_of_week_time_ranges,
                 values: [
                   "M/13:00:00-15:00:00,19:00:00-22:00:00/Poland",
                   "F/08:00:00-20:00:00/UTC",
                   "S/true/US/Pacific"
                 ]
               }
             ]
    end

    test "broadcasts an account message when policy is created", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      attrs = %{
        actor_group_id: actor_group.id,
        resource_id: resource.id
      }

      :ok = subscribe_to_events_for_account(account)

      assert {:ok, policy} = create_policy(attrs, subject)

      assert_receive {:create_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts an actor group message when policy is created", %{
      account: account,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      attrs = %{
        actor_group_id: actor_group.id,
        resource_id: resource.id
      }

      :ok = subscribe_to_events_for_actor_group(actor_group)

      assert {:ok, policy} = create_policy(attrs, subject)

      assert_receive {:allow_access, policy_id, actor_group_id, resource_id}
      assert policy_id == policy.id
      assert actor_group_id == actor_group.id
      assert resource_id == resource.id
    end
  end

  describe "update_policy/3" do
    setup context do
      policy =
        Fixtures.Policies.create_policy(
          account: context.account,
          subject: context.subject,
          conditions: [
            %{
              property: :remote_ip,
              operator: :is_in_cidr,
              values: ["1.0.0.0/24"]
            }
          ]
        )

      Map.put(context, :policy, policy)
    end

    test "does nothing on empty params", %{policy: policy, subject: subject} do
      assert {:updated, _policy} = update_policy(policy, %{}, subject)
    end

    test "returns changeset error on invalid params", %{account: account, subject: subject} do
      policy = Fixtures.Policies.create_policy(account: account, subject: subject)

      attrs = %{description: String.duplicate("a", 1025)}
      assert {:error, changeset} = update_policy(policy, attrs, subject)
      assert errors_on(changeset) == %{description: ["should be at most 1024 character(s)"]}
    end

    test "allows update to description", %{policy: policy, subject: subject} do
      attrs = %{description: "updated policy description"}
      assert {:updated, updated_policy} = update_policy(policy, attrs, subject)
      assert updated_policy.description == attrs.description
    end

    test "broadcasts an account message when policy is updated", %{
      account: account,
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_account(account)

      attrs = %{description: "updated policy description"}
      assert {:updated, policy} = update_policy(policy, attrs, subject)

      assert_receive {:update_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts a policy message when policy is updated", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_policy(policy)

      attrs = %{description: "updated policy description"}
      assert {:updated, updated_policy} = update_policy(policy, attrs, subject)
      assert updated_policy.id == policy.id

      assert_receive {:update_policy, policy_id}
      assert policy_id == policy.id
    end

    test "does not broadcast an actor group message when policy is updated", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_actor_group(policy.actor_group_id)

      attrs = %{description: "updated policy description"}
      assert {:updated, _policy} = update_policy(policy, attrs, subject)

      refute_receive {:allow_access, _policy_id, _actor_group_id, _resource_id}
      refute_receive {:reject_access, _policy_id, _actor_group_id, _resource_id}
    end

    test "updates a policy when resource_id is changed", %{
      policy: policy,
      account: account,
      subject: subject
    } do
      new_resource = Fixtures.Resources.create_resource(account: account)

      attrs = %{resource_id: new_resource.id}

      assert {:updated, updated_policy} = update_policy(policy, attrs, subject)

      assert updated_policy.resource_id != policy.resource_id
      assert updated_policy.resource_id == attrs[:resource_id]
      assert updated_policy.actor_group_id == policy.actor_group_id
      assert updated_policy.conditions == policy.conditions
    end

    test "updates policy when actor_group_id is changed", %{
      policy: policy,
      account: account,
      subject: subject
    } do
      new_actor_group = Fixtures.Actors.create_group(account: account)

      attrs = %{actor_group_id: new_actor_group.id}

      assert {:updated, updated_policy} =
               update_policy(policy, attrs, subject)

      assert updated_policy.id == policy.id
      assert updated_policy.resource_id == policy.resource_id
      assert updated_policy.actor_group_id != policy.actor_group_id
      assert updated_policy.actor_group_id == attrs[:actor_group_id]
      assert updated_policy.conditions == policy.conditions
    end

    test "updates a policy when conditions are changed", %{
      policy: policy,
      subject: subject
    } do
      attrs = %{
        conditions: [
          %{
            property: :remote_ip,
            operator: :is_in_cidr,
            values: ["2.0.0.0/24"]
          }
        ]
      }

      assert {:updated, updated_policy} =
               update_policy(policy, attrs, subject)

      assert updated_policy.id == policy.id
      assert updated_policy.resource_id == policy.resource_id
      assert updated_policy.actor_group_id == policy.actor_group_id

      refute updated_policy.conditions == [
               %Domain.Policies.Condition{
                 property: :remote_ip,
                 operator: :is_in_cidr,
                 values: ["1.0.0.0/24"]
               }
             ]

      assert updated_policy.conditions == [
               %Domain.Policies.Condition{
                 property: :remote_ip,
                 operator: :is_in_cidr,
                 values: ["2.0.0.0/24"]
               }
             ]
    end

    test "broadcasts events and expires flow for updated policy", %{
      policy: policy,
      account: account,
      subject: subject
    } do
      flow = Fixtures.Flows.create_flow(account: account, subject: subject, policy: policy)
      new_resource = Fixtures.Resources.create_resource(account: account)
      new_actor_group = Fixtures.Actors.create_group(account: account)

      :ok = subscribe_to_events_for_policy(policy)
      :ok = subscribe_to_events_for_actor_group(policy.actor_group_id)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      attrs = %{resource_id: new_resource.id, actor_group_id: new_actor_group.id}

      assert {:updated, updated_policy} = update_policy(policy, attrs, subject)

      # Updating a policy sends delete and create events
      assert_receive {:delete_policy, policy_id}
      assert policy_id == policy.id

      assert_receive {:create_policy, policy_id}
      assert policy_id == updated_policy.id

      assert_receive {:reject_access, policy_id, actor_group_id, resource_id}
      assert policy_id == policy.id
      assert actor_group_id == policy.actor_group_id
      assert resource_id == policy.resource_id

      assert_receive {:expire_flow, flow_id, _flow_client_id, _flow_resource_id}
      assert flow_id == flow.id
    end

    test "returns error when subject has no permission to update policies", %{
      policy: policy,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)
      attrs = %{description: "Name Change Attempt"}

      assert update_policy(policy, attrs, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Policies.Authorizer.manage_policies_permission()]}}
    end

    test "return error when subject is outside of account", %{policy: policy} do
      other_account = Fixtures.Accounts.create_account()

      other_actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: other_account)

      other_identity = Fixtures.Auth.create_identity(account: other_account, actor: other_actor)
      other_subject = Fixtures.Auth.create_subject(identity: other_identity)

      assert update_policy(
               policy,
               %{description: "Should not be allowed"},
               other_subject
             ) ==
               {:error, :unauthorized}
    end
  end

  describe "disable_policy/2" do
    setup %{account: account, subject: subject} do
      policy =
        Fixtures.Policies.create_policy(
          account: account,
          subject: subject
        )

      %{policy: policy}
    end

    test "disables a given policy", %{
      account: account,
      subject: subject,
      policy: policy
    } do
      other_policy = Fixtures.Policies.create_policy(account: account)

      assert {:ok, policy} = disable_policy(policy, subject)
      assert policy.disabled_at

      assert policy = Repo.get(Policies.Policy, policy.id)
      assert policy.disabled_at

      assert other_policy = Repo.get(Policies.Policy, other_policy.id)
      assert is_nil(other_policy.disabled_at)
    end

    test "expires policy flows", %{
      account: account,
      policy: policy,
      identity: identity,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          policy: policy
        )

      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      assert {:ok, _policy} = disable_policy(policy, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1

      assert_received {:expire_flow, flow_id, _flow_client_id, _flow_resource_id}
      assert flow_id == flow.id
    end

    test "broadcasts an account message when policy is disabled", %{
      account: account,
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_account(account)

      assert {:ok, policy} = disable_policy(policy, subject)

      assert_receive {:disable_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts a policy message when policy is disabled", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_policy(policy)

      assert {:ok, policy} = disable_policy(policy, subject)

      assert_receive {:disable_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts an actor group message when policy is disabled", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_actor_group(policy.actor_group_id)

      assert {:ok, policy} = disable_policy(policy, subject)

      assert_receive {:reject_access, policy_id, actor_group_id, resource_id}
      assert policy_id == policy.id
      assert actor_group_id == policy.actor_group_id
      assert resource_id == policy.resource_id
    end

    test "does not do anything when an policy is disabled twice", %{
      subject: subject,
      account: account
    } do
      policy = Fixtures.Policies.create_policy(account: account)
      assert {:ok, _policy} = disable_policy(policy, subject)
      assert {:ok, policy} = disable_policy(policy, subject)
      assert {:ok, _policy} = disable_policy(policy, subject)
    end

    test "does not allow to disable policies in other accounts", %{
      subject: subject
    } do
      policy = Fixtures.Policies.create_policy()
      assert disable_policy(policy, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot disable policies", %{
      subject: subject,
      policy: policy
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert disable_policy(policy, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Policies.Authorizer.manage_policies_permission()]}}
    end
  end

  describe "enable_policy/2" do
    setup context do
      policy =
        Fixtures.Policies.create_policy(
          account: context.account,
          subject: context.subject
        )

      {:ok, policy} = disable_policy(policy, context.subject)

      Map.put(context, :policy, policy)
    end

    test "enables a given policy", %{
      subject: subject,
      policy: policy
    } do
      assert {:ok, policy} = enable_policy(policy, subject)
      assert is_nil(policy.disabled_at)

      assert policy = Repo.get(Policies.Policy, policy.id)
      assert is_nil(policy.disabled_at)
    end

    test "broadcasts an account message when policy is enabled", %{
      account: account,
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_account(account)

      assert {:ok, policy} = enable_policy(policy, subject)

      assert_receive {:enable_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts a policy message when policy is enabled", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_policy(policy)

      assert {:ok, policy} = enable_policy(policy, subject)

      assert_receive {:enable_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts an actor group message when policy is enabled", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_actor_group(policy.actor_group_id)

      assert {:ok, policy} = enable_policy(policy, subject)

      assert_receive {:allow_access, policy_id, actor_group_id, resource_id}
      assert policy_id == policy.id
      assert actor_group_id == policy.actor_group_id
      assert resource_id == policy.resource_id
    end

    test "does not do anything when an policy is enabled twice", %{
      subject: subject,
      policy: policy
    } do
      assert {:ok, _policy} = enable_policy(policy, subject)
      assert {:ok, policy} = enable_policy(policy, subject)
      assert {:ok, _policy} = enable_policy(policy, subject)
    end

    test "does not allow to enable policies in other accounts", %{
      subject: subject
    } do
      policy = Fixtures.Policies.create_policy()
      assert enable_policy(policy, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot enable policies", %{
      subject: subject,
      policy: policy
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert enable_policy(policy, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Policies.Authorizer.manage_policies_permission()]}}
    end
  end

  describe "delete_policy/2" do
    setup context do
      policy =
        Fixtures.Policies.create_policy(
          account: context.account,
          subject: context.subject
        )

      Map.put(context, :policy, policy)
    end

    test "deletes policy", %{policy: policy, subject: subject} do
      assert {:ok, deleted_policy} = delete_policy(policy, subject)
      assert deleted_policy.deleted_at != nil
    end

    test "expires policy flows", %{
      account: account,
      policy: policy,
      identity: identity,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          policy: policy
        )

      :ok = Domain.Flows.subscribe_to_flow_expiration_events(flow)

      assert {:ok, _policy} = delete_policy(policy, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1

      assert_received {:expire_flow, flow_id, _flow_client_id, _flow_resource_id}
      assert flow_id == flow.id
    end

    test "broadcasts an account message when policy is deleted", %{
      account: account,
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_account(account)

      assert {:ok, policy} = delete_policy(policy, subject)

      assert_receive {:delete_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts a policy message when policy is deleted", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_policy(policy)

      assert {:ok, policy} = delete_policy(policy, subject)

      assert_receive {:delete_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts an actor group message when policy is deleted", %{
      subject: subject,
      policy: policy
    } do
      :ok = subscribe_to_events_for_actor_group(policy.actor_group_id)

      assert {:ok, policy} = delete_policy(policy, subject)

      assert_receive {:reject_access, policy_id, actor_group_id, resource_id}
      assert policy_id == policy.id
      assert actor_group_id == policy.actor_group_id
      assert resource_id == policy.resource_id
    end

    test "returns error when subject has no permission to delete policies", %{
      policy: policy,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_policy(policy, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Policies.Authorizer.manage_policies_permission()]}}
    end

    test "returns error on state conflict", %{policy: policy, subject: subject} do
      assert {:ok, deleted_policy} = delete_policy(policy, subject)
      assert delete_policy(deleted_policy, subject) == {:error, :not_found}
      assert delete_policy(policy, subject) == {:error, :not_found}
    end

    test "returns error when subject attempts to delete policy outside of account", %{
      policy: policy
    } do
      other_subject = Fixtures.Auth.create_subject()
      assert delete_policy(policy, other_subject) == {:error, :not_found}
    end
  end

  describe "delete_policies_for/1" do
    setup %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource,
          actor_group: actor_group,
          subject: subject
        )

      %{
        resource: resource,
        actor_group: actor_group,
        policy: policy
      }
    end

    test "deletes policies for actor group provider", %{
      actor_group: actor_group,
      policy: policy
    } do
      assert {:ok, [deleted_policy]} = delete_policies_for(actor_group)
      refute is_nil(deleted_policy.deleted_at)
      assert deleted_policy.id == policy.id

      refute is_nil(Repo.get(Policies.Policy, policy.id).deleted_at)
    end
  end

  describe "delete_policies_for/2" do
    setup %{account: account, subject: subject} do
      resource = Fixtures.Resources.create_resource(account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource,
          actor_group: actor_group,
          subject: subject
        )

      %{
        resource: resource,
        actor_group: actor_group,
        policy: policy
      }
    end

    test "deletes policies for actor group", %{
      account: account,
      policy: policy,
      actor_group: actor_group,
      subject: subject
    } do
      other_policy = Fixtures.Policies.create_policy(account: account, subject: subject)

      assert {:ok, [deleted_policy]} = delete_policies_for(actor_group, subject)
      refute is_nil(deleted_policy.deleted_at)
      assert deleted_policy.id == policy.id

      refute is_nil(Repo.get(Policies.Policy, policy.id).deleted_at)
      assert is_nil(Repo.get(Policies.Policy, other_policy.id).deleted_at)
    end

    test "deletes policies for actor group provider", %{
      account: account,
      resource: resource,
      policy: other_policy,
      subject: subject
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      actor_group = Fixtures.Actors.create_group(account: account, provider: provider)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource,
          actor_group: actor_group,
          subject: subject
        )

      assert {:ok, [deleted_policy]} = delete_policies_for(provider, subject)
      refute is_nil(deleted_policy.deleted_at)
      assert deleted_policy.id == policy.id

      refute is_nil(Repo.get(Policies.Policy, policy.id).deleted_at)
      assert is_nil(Repo.get(Policies.Policy, other_policy.id).deleted_at)
    end

    test "deletes policies for resource", %{
      account: account,
      policy: policy,
      resource: resource,
      subject: subject
    } do
      other_policy = Fixtures.Policies.create_policy(account: account, subject: subject)

      assert {:ok, [deleted_policy]} = delete_policies_for(resource, subject)
      refute is_nil(deleted_policy.deleted_at)
      assert deleted_policy.id == policy.id

      assert is_nil(Repo.get(Policies.Policy, other_policy.id).deleted_at)
    end

    test "expires policy flows", %{
      account: account,
      identity: identity,
      policy: policy,
      resource: resource,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      Fixtures.Flows.create_flow(
        account: account,
        subject: subject,
        client: client,
        policy: policy,
        resource: resource
      )

      assert {:ok, [_deleted_policy]} = delete_policies_for(resource, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
    end

    test "broadcasts an account message when policy is deleted", %{
      account: account,
      resource: resource,
      subject: subject
    } do
      :ok = subscribe_to_events_for_account(account)

      assert {:ok, [policy]} = delete_policies_for(resource, subject)

      assert_receive {:delete_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts a policy message when policy is deleted", %{
      resource: resource,
      policy: policy,
      subject: subject
    } do
      :ok = subscribe_to_events_for_policy(policy)

      assert {:ok, [policy]} = delete_policies_for(resource, subject)

      assert_receive {:delete_policy, policy_id}
      assert policy_id == policy.id
    end

    test "broadcasts an actor group message when policy is deleted", %{
      resource: resource,
      actor_group: actor_group,
      subject: subject
    } do
      :ok = subscribe_to_events_for_actor_group(actor_group)

      assert {:ok, [policy]} = delete_policies_for(resource, subject)

      assert_receive {:reject_access, policy_id, actor_group_id, resource_id}
      assert policy_id == policy.id
      assert actor_group_id == policy.actor_group_id
      assert resource_id == policy.resource_id
    end

    test "returns error when subject has no permission to delete policies", %{
      resource: resource,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_policies_for(resource, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Policies.Authorizer.manage_policies_permission()]}}
    end

    test "does not do anything on state conflict", %{
      resource: resource,
      actor_group: actor_group,
      subject: subject
    } do
      assert {:ok, [_deleted_policy]} = delete_policies_for(resource, subject)
      assert delete_policies_for(actor_group, subject) == {:ok, []}
      assert delete_policies_for(resource, subject) == {:ok, []}
    end

    test "does not delete policies outside of account", %{
      resource: resource
    } do
      subject = Fixtures.Auth.create_subject()
      assert delete_policies_for(resource, subject) == {:ok, []}
    end
  end

  describe "ensure_client_conforms_policy_conditions/2" do
    test "returns :ok when client conforms to policy conditions", %{} do
      client = %Domain.Clients.Client{
        last_seen_remote_ip_location_region: "US"
      }

      policy = %Policies.Policy{
        conditions: [
          %Policies.Condition{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["US"]
          }
        ]
      }

      assert ensure_client_conforms_policy_conditions(client, policy) == {:ok, nil}
    end

    test "returns error when client conforms to policy conditions", %{} do
      client = %Domain.Clients.Client{
        last_seen_remote_ip_location_region: "US"
      }

      policy = %Policies.Policy{
        conditions: [
          %Policies.Condition{
            property: :remote_ip_location_region,
            operator: :is_in,
            values: ["CA"]
          }
        ]
      }

      assert ensure_client_conforms_policy_conditions(client, policy) ==
               {:error, {:forbidden, [violated_properties: [:remote_ip_location_region]]}}
    end
  end
end
