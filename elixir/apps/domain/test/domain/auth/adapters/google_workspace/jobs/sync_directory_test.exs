defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs.SyncDirectoryTest do
  use Domain.DataCase, async: true
  alias Domain.{Auth, Actors}
  alias Domain.Mocks.GoogleWorkspaceDirectory
  import Domain.Auth.Adapters.GoogleWorkspace.Jobs.SyncDirectory

  describe "execute/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

      %{
        bypass: bypass,
        account: account,
        provider: provider
      }
    end

    test "returns error when IdP sync is not enabled", %{account: account, provider: provider} do
      {:ok, _account} = Domain.Accounts.update_account(account, %{features: %{idp_sync: false}})

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1

      assert updated_provider.last_sync_error ==
               "IdP sync is not enabled in your subscription plan"
    end

    test "uses service account token when it's available" do
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"groups" => []})
      )

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"organizationUnits" => []})
      )

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"users" => []})
      )

      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert_receive {:bypass_request,
                      %{req_headers: [{"authorization", "Bearer GOOGLE_0AUTH_ACCESS_TOKEN"} | _]}}
    end

    test "does not use admin user token when service account is set" do
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_token_endpoint("http://localhost:#{bypass.port}/")

      Bypass.stub(bypass, "POST", "/token", fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          Jason.encode!(%{
            "error" => "unauthorized_client",
            "error_description" =>
              "Client is unauthorized to retrieve access tokens using this method, or client not authorized for any of the scopes requested."
          })
        )
      end)

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      {:ok, pid} = Task.Supervisor.start_link()

      assert execute(%{task_supervisor: pid}) == :ok

      refute_receive {:bypass_request,
                      %{req_headers: [{"authorization", "Bearer OIDC_ACCESS_TOKEN"} | _]}}
    end

    test "uses admin user token as a fallback when service account token is not set", %{
      provider: provider
    } do
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"groups" => []})
      )

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"organizationUnits" => []})
      )

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"users" => []})
      )

      provider
      |> Ecto.Changeset.change(
        adapter_config: Map.put(provider.adapter_config, "service_account_json_key", nil)
      )
      |> Repo.update!()

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert_receive {:bypass_request,
                      %{req_headers: [{"authorization", "Bearer OIDC_ACCESS_TOKEN"} | _]}}
    end

    test "syncs IdP data", %{provider: provider} do
      bypass = Bypass.open()

      groups = [
        %{
          "kind" => "admin#directory#group",
          "id" => "GROUP_ID1",
          "etag" => "\"ET\"",
          "email" => "i@fiez.xxx",
          "name" => "Infrastructure",
          "directMembersCount" => "5",
          "description" => "Group to handle infrastructure alerts and management",
          "adminCreated" => true,
          "aliases" => [
            "pnr@firez.one"
          ],
          "nonEditableAliases" => [
            "i@ext.fiez.xxx"
          ]
        }
      ]

      organization_units = [
        %{
          "kind" => "admin#directory#orgUnit",
          "name" => "Engineering",
          "description" => "Engineering team",
          "etag" => "\"ET\"",
          "blockInheritance" => false,
          "orgUnitId" => "OU_ID1",
          "orgUnitPath" => "/Engineering",
          "parentOrgUnitId" => "OU_ID0",
          "parentOrgUnitPath" => "/"
        },
        %{
          "kind" => "admin#directory#orgUnit",
          "name" => "Developers",
          "description" => "Developers team",
          "etag" => "\"DEVT\"",
          "blockInheritance" => false,
          "orgUnitId" => "OU_ID2",
          "orgUnitPath" => "/Engineering/Developers",
          "parentOrgUnitId" => "OU_ID1",
          "parentOrgUnitPath" => "/Engineering"
        }
      ]

      users = [
        %{
          "agreedToTerms" => true,
          "archived" => false,
          "changePasswordAtNextLogin" => false,
          "creationTime" => "2023-06-10T17:32:06.000Z",
          "customerId" => "CustomerID1",
          "emails" => [
            %{"address" => "b@firez.xxx", "primary" => true},
            %{"address" => "b@ext.firez.xxx"}
          ],
          "etag" => "\"ET-61Bnx4\"",
          "id" => "USER_ID1",
          "includeInGlobalAddressList" => true,
          "ipWhitelisted" => false,
          "isAdmin" => false,
          "isDelegatedAdmin" => false,
          "isEnforcedIn2Sv" => false,
          "isEnrolledIn2Sv" => false,
          "isMailboxSetup" => true,
          "kind" => "admin#directory#user",
          "languages" => [%{"languageCode" => "en", "preference" => "preferred"}],
          "lastLoginTime" => "2023-06-26T13:53:30.000Z",
          "name" => %{
            "familyName" => "Manifold",
            "fullName" => "Brian Manifold",
            "givenName" => "Brian"
          },
          "nonEditableAliases" => ["b@ext.firez.xxx"],
          "orgUnitPath" => "/Engineering/Developers",
          "organizations" => [
            %{
              "customType" => "",
              "department" => "Engineering",
              "location" => "",
              "name" => "Firezone, Inc.",
              "primary" => true,
              "title" => "Senior Fullstack Engineer",
              "type" => "work"
            }
          ],
          "phones" => [%{"type" => "mobile", "value" => "(567) 111-2233"}],
          "primaryEmail" => "b@firez.xxx",
          "recoveryEmail" => "xxx@xxx.com",
          "suspended" => false,
          "thumbnailPhotoEtag" => "\"ET\"",
          "thumbnailPhotoUrl" =>
            "https://lh3.google.com/ao/AP2z2aWvm9JM99oCFZ1TVOJgQZlmZdMMYNr7w9G0jZApdTuLHfAueGFb_XzgTvCNRhGw=s96-c"
        },
        %{
          "agreedToTerms" => true,
          "archived" => false,
          "changePasswordAtNextLogin" => false,
          "creationTime" => "2023-06-10T17:32:06.000Z",
          "customerId" => "CustomerID1",
          "emails" => [
            %{"address" => "j@firez.xxx", "primary" => true},
            %{"address" => "j@ext.firez.xxx"}
          ],
          "etag" => "\"ET-61Bnx4\"",
          "id" => "USER_ID2",
          "includeInGlobalAddressList" => true,
          "ipWhitelisted" => false,
          "isAdmin" => false,
          "isDelegatedAdmin" => false,
          "isEnforcedIn2Sv" => false,
          "isEnrolledIn2Sv" => false,
          "isMailboxSetup" => true,
          "kind" => "admin#directory#user",
          "languages" => [%{"languageCode" => "en", "preference" => "preferred"}],
          "lastLoginTime" => "2023-06-26T13:53:30.000Z",
          "name" => %{
            "familyName" => "Jamil",
            "fullName" => "Jamil Bou Kheir",
            "givenName" => "Bou Kheir"
          },
          "nonEditableAliases" => ["j@ext.firez.xxx"],
          "orgUnitPath" => "/",
          "organizations" => [],
          "phones" => [%{"type" => "mobile", "value" => "(567) 111-2234"}],
          "primaryEmail" => "j@firez.xxx",
          "recoveryEmail" => "xxx@xxx.com",
          "suspended" => false,
          "thumbnailPhotoEtag" => "\"ET\"",
          "thumbnailPhotoUrl" =>
            "https://lh3.google.com/ao/AP2z2aWvm9JM99oCFZ1TVOJgQZlmZdMMYNr7w9G0jZApdTuLHfAueGFb_XzgTvCNRhGw=s96-c"
        }
      ]

      members = [
        %{
          "kind" => "admin#directory#member",
          "etag" => "\"ET\"",
          "id" => "USER_ID1",
          "email" => "b@firez.xxx",
          "role" => "MEMBER",
          "type" => "USER",
          "status" => "ACTIVE"
        }
      ]

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"groups" => groups})
      )

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"organizationUnits" => organization_units})
      )

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"users" => users})
      )

      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      Enum.each(groups, fn group ->
        GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
          bypass,
          group["id"],
          200,
          Jason.encode!(%{"members" => members})
        )
      end)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      groups = Actors.Group |> Repo.all()
      assert length(groups) == 3

      for group <- groups do
        assert group.provider_identifier in ["G:GROUP_ID1", "OU:OU_ID1", "OU:OU_ID2"]
        assert group.name in ["OrgUnit:Engineering", "OrgUnit:Developers", "Group:Infrastructure"]

        assert group.inserted_at
        assert group.updated_at

        assert group.created_by == :provider
        assert group.provider_id == provider.id
      end

      identities = Auth.Identity |> Repo.all() |> Repo.preload(:actor)
      assert length(identities) == 2

      for identity <- identities do
        assert identity.inserted_at
        assert identity.created_by == :provider
        assert identity.provider_id == provider.id
        assert identity.provider_identifier in ["USER_ID1", "USER_ID2"]

        assert identity.provider_state in [
                 %{"userinfo" => %{"email" => "b@firez.xxx"}},
                 %{"userinfo" => %{"email" => "j@firez.xxx"}}
               ]

        assert identity.actor.name in ["Brian Manifold", "Jamil Bou Kheir"]
        assert identity.actor.last_synced_at
      end

      memberships = Actors.Membership |> Repo.all()
      assert length(memberships) == 3

      updated_provider = Repo.get!(Domain.Auth.Provider, provider.id)
      assert updated_provider.last_synced_at != provider.last_synced_at
    end

    test "does not crash on endpoint errors" do
      bypass = Bypass.open()
      Bypass.down(bypass)
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert Repo.aggregate(Actors.Group, :count) == 0
    end

    test "updates existing identities and actors", %{account: account, provider: provider} do
      bypass = Bypass.open()

      users = [
        %{
          "agreedToTerms" => true,
          "archived" => false,
          "creationTime" => "2023-06-10T17:32:06.000Z",
          "id" => "USER_ID1",
          "kind" => "admin#directory#user",
          "lastLoginTime" => "2023-06-26T13:53:30.000Z",
          "name" => %{
            "familyName" => "Manifold",
            "fullName" => "Brian Manifold",
            "givenName" => "Brian"
          },
          "orgUnitPath" => "/",
          "organizations" => [],
          "phones" => [],
          "primaryEmail" => "b@firez.xxx"
        }
      ]

      actor = Fixtures.Actors.create_actor(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
          provider_identifier: "USER_ID1"
        )

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"groups" => []})
      )

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"organizationUnits" => []})
      )

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"users" => users})
      )

      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_identity =
               Repo.get(Domain.Auth.Identity, identity.id)
               |> Repo.preload(:actor)

      assert updated_identity.provider_state == %{"userinfo" => %{"email" => "b@firez.xxx"}}
      assert updated_identity.actor.name == "Brian Manifold"
      assert updated_identity.actor.last_synced_at
    end

    test "updates existing groups and memberships", %{account: account, provider: provider} do
      bypass = Bypass.open()

      users = [
        %{
          "agreedToTerms" => true,
          "archived" => false,
          "creationTime" => "2023-06-10T17:32:06.000Z",
          "id" => "USER_ID1",
          "kind" => "admin#directory#user",
          "lastLoginTime" => "2023-06-26T13:53:30.000Z",
          "name" => %{
            "familyName" => "Manifold",
            "fullName" => "Brian Manifold",
            "givenName" => "Brian"
          },
          "orgUnitPath" => "/Engineering",
          "organizations" => [],
          "phones" => [],
          "primaryEmail" => "b@firez.xxx"
        },
        %{
          "agreedToTerms" => true,
          "archived" => false,
          "creationTime" => "2023-06-10T17:32:06.000Z",
          "id" => "USER_ID2",
          "kind" => "admin#directory#user",
          "lastLoginTime" => "2023-06-26T13:53:30.000Z",
          "name" => %{
            "familyName" => "Jamil",
            "fullName" => "Jamil Bou Kheir",
            "givenName" => "Bou Kheir"
          },
          "orgUnitPath" => "/",
          "organizations" => [],
          "phones" => [],
          "primaryEmail" => "j@firez.xxx"
        }
      ]

      groups = [
        %{
          "kind" => "admin#directory#group",
          "id" => "GROUP_ID1",
          "etag" => "\"ET\"",
          "email" => "i@fiez.xxx",
          "name" => "Infrastructure",
          "directMembersCount" => "5",
          "description" => "Group to handle infrastructure alerts and management",
          "adminCreated" => true,
          "aliases" => [
            "pnr@firez.one"
          ],
          "nonEditableAliases" => [
            "i@ext.fiez.xxx"
          ]
        },
        %{
          "kind" => "admin#directory#group",
          "id" => "GROUP_ID2",
          "etag" => "\"ET\"",
          "email" => "i@fiez.xxx",
          "name" => "Devs",
          "directMembersCount" => "1",
          "description" => "Group for devs",
          "adminCreated" => true,
          "aliases" => [
            "pnr@firez.one"
          ],
          "nonEditableAliases" => [
            "i@ext.fiez.xxx"
          ]
        }
      ]

      organization_units = [
        %{
          "kind" => "admin#directory#orgUnit",
          "name" => "Engineering",
          "description" => "Engineering team",
          "etag" => "\"ET\"",
          "blockInheritance" => false,
          "orgUnitId" => "OU_ID1",
          "orgUnitPath" => "/Engineering",
          "parentOrgUnitId" => "OU_ID0",
          "parentOrgUnitPath" => "/"
        }
      ]

      one_member = [
        %{
          "kind" => "admin#directory#member",
          "etag" => "\"ET\"",
          "id" => "USER_ID1",
          "email" => "b@firez.xxx",
          "role" => "MEMBER",
          "type" => "USER",
          "status" => "ACTIVE"
        }
      ]

      two_members =
        one_member ++
          [
            %{
              "kind" => "admin#directory#member",
              "etag" => "\"ET\"",
              "id" => "USER_ID2",
              "email" => "j@firez.xxx",
              "role" => "MEMBER",
              "type" => "USER",
              "status" => "ACTIVE"
            }
          ]

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: "USER_ID1"
      )

      other_actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: other_actor,
        provider_identifier: "USER_ID2"
      )

      deleted_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: other_actor,
          provider_identifier: "USER_ID2_2"
        )

      deleted_identity_token =
        Fixtures.Tokens.create_token(
          account: account,
          actor: other_actor,
          identity: deleted_identity
        )

      deleted_identity_client =
        Fixtures.Clients.create_client(
          account: account,
          actor: other_actor,
          identity: deleted_identity
        )

      deleted_identity_flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: deleted_identity_client,
          token_id: deleted_identity_token.id
        )

      group =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_ID1"
        )

      deleted_group =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:DELETED_GROUP_ID!"
        )

      org_unit =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "OU:OU_ID1"
        )

      policy = Fixtures.Policies.create_policy(account: account, actor_group: group)

      deleted_policy =
        Fixtures.Policies.create_policy(account: account, actor_group: deleted_group)

      deleted_group_flow =
        Fixtures.Flows.create_flow(
          account: account,
          actor_group: deleted_group,
          resource_id: deleted_policy.resource_id,
          policy: deleted_policy
        )

      Fixtures.Actors.create_membership(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)
      deleted_membership = Fixtures.Actors.create_membership(account: account, group: group)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: deleted_group)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: org_unit)

      :ok = Domain.Actors.subscribe_to_membership_updates_for_actor(actor)
      :ok = Domain.Actors.subscribe_to_membership_updates_for_actor(other_actor)
      :ok = Domain.Actors.subscribe_to_membership_updates_for_actor(deleted_membership.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor(other_actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(deleted_group)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(deleted_group_flow)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(deleted_identity_flow)
      :ok = Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{deleted_identity_token.id}")

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"groups" => groups})
      )

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"organizationUnits" => organization_units})
      )

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"users" => users})
      )

      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_ID1",
        200,
        Jason.encode!(%{"members" => two_members})
      )

      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_ID2",
        200,
        Jason.encode!(%{"members" => one_member})
      )

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_group = Repo.get(Domain.Actors.Group, group.id)
      assert updated_group.name == "Group:Infrastructure"

      assert updated_org_unit = Repo.get(Domain.Actors.Group, org_unit.id)
      assert updated_org_unit.name == "OrgUnit:Engineering"

      assert created_group = Repo.get_by(Domain.Actors.Group, provider_identifier: "G:GROUP_ID2")
      assert created_group.name == "Group:Devs"

      assert memberships = Repo.all(Domain.Actors.Membership.Query.all())
      assert length(memberships) == 5

      assert memberships = Repo.all(Domain.Actors.Membership.Query.with_joined_groups())
      assert length(memberships) == 5

      membership_group_ids = Enum.map(memberships, & &1.group_id)
      assert group.id in membership_group_ids
      assert org_unit.id in membership_group_ids
      assert deleted_group.id not in membership_group_ids

      # Deletes membership for a deleted group
      actor_id = actor.id
      group_id = deleted_group.id
      assert_receive {:delete_membership, ^actor_id, ^group_id}

      # Created membership for a new group
      actor_id = actor.id
      group_id = created_group.id
      assert_receive {:create_membership, ^actor_id, ^group_id}

      # Created membership for a member of existing group
      other_actor_id = other_actor.id
      group_id = group.id
      assert_receive {:create_membership, ^other_actor_id, ^group_id}

      # Broadcasts allow_access for it
      policy_id = policy.id
      group_id = group.id
      resource_id = policy.resource_id
      assert_receive {:allow_access, ^policy_id, ^group_id, ^resource_id}

      # Deletes membership that is not found on IdP end
      actor_id = deleted_membership.actor_id
      group_id = deleted_membership.group_id
      assert_receive {:delete_membership, ^actor_id, ^group_id}

      # Signs out users which identity has been deleted
      topic = "sessions:#{deleted_identity_token.id}"
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: nil}

      # Deleted group deletes all policies and broadcasts reject access events for them
      policy_id = deleted_policy.id
      group_id = deleted_group.id
      resource_id = deleted_policy.resource_id
      assert_receive {:reject_access, ^policy_id, ^group_id, ^resource_id}

      # Deleted policies expire all flows authorized by them
      flow_id = deleted_group_flow.id
      assert_receive {:expire_flow, ^flow_id, _client_id, ^resource_id}

      # Expires flows for signed out user
      flow_id = deleted_identity_flow.id
      assert_receive {:expire_flow, ^flow_id, _client_id, _resource_id}

      # Should not do anything else
      refute_receive {:create_membership, _actor_id, _group_id}
      refute_received {:remove_membership, _actor_id, _group_id}
      refute_received {:allow_access, _policy_id, _group_id, _resource_id}
      refute_received {:reject_access, _policy_id, _group_id, _resource_id}
      refute_received {:expire_flow, _flow_id, _client_id, _resource_id}
    end

    test "resurrects deleted identities that reappear on the next sync", %{
      account: account,
      provider: provider
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      provider_identifier = "USER_ID1"

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
          provider_identifier: provider_identifier
        )

      inserted_at = identity.inserted_at
      id = identity.id

      # Soft delete the identity
      Repo.update_all(Domain.Auth.Identity, set: [deleted_at: DateTime.utc_now()])

      assert Domain.Auth.all_identities_for(actor) == []

      # Simulate a sync
      bypass = Bypass.open()

      users = [
        %{
          "agreedToTerms" => true,
          "archived" => false,
          "creationTime" => "2023-06-10T17:32:06.000Z",
          "id" => "USER_ID1",
          "kind" => "admin#directory#user",
          "lastLoginTime" => "2023-06-26T13:53:30.000Z",
          "name" => %{
            "familyName" => "Manifold",
            "fullName" => "Brian Manifold",
            "givenName" => "Brian"
          },
          "orgUnitPath" => "/Engineering",
          "organizations" => [],
          "phones" => [],
          "primaryEmail" => "b@firez.xxx"
        }
      ]

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, [])
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, [])
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, users)
      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      # Assert that the identity has been resurrected
      assert resurrected_identity = Repo.get(Domain.Auth.Identity, id)
      assert resurrected_identity.inserted_at == inserted_at
      assert resurrected_identity.id == id
      assert resurrected_identity.deleted_at == nil
      assert Domain.Auth.all_identities_for(actor) == [resurrected_identity]
    end

    test "resurrects deleted groups that reappear on the next sync", %{
      account: account,
      provider: provider
    } do
      actor_group =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_ID1"
        )

      inserted_at = actor_group.inserted_at
      id = actor_group.id

      # Soft delete the group
      Repo.update_all(Domain.Actors.Group, set: [deleted_at: DateTime.utc_now()])

      # Assert that the group and associated policy has been soft-deleted
      assert Domain.Actors.Group.Query.not_deleted() |> Repo.all() == []

      # Simulate a sync
      bypass = Bypass.open()

      groups = [
        %{
          "kind" => "admin#directory#group",
          "id" => "GROUP_ID1",
          "etag" => "\"ET\"",
          "email" => "i@fiez.xxx",
          "name" => "Infrastructure",
          "directMembersCount" => "5",
          "description" => "Group to handle infrastructure alerts and management",
          "adminCreated" => true,
          "aliases" => [
            "pnr@firez.one"
          ],
          "nonEditableAliases" => [
            "i@ext.fiez.xxx"
          ]
        }
      ]

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, groups)
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, [])
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, [])
      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, "GROUP_ID1", [])
      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      # Assert that the group has been resurrected
      assert resurrected_group = Repo.get(Domain.Actors.Group, id)
      assert resurrected_group.inserted_at == inserted_at
      assert resurrected_group.id == id
      assert resurrected_group.deleted_at == nil
      assert Domain.Actors.Group.Query.not_deleted() |> Repo.all() == [resurrected_group]

      # TODO:: Test that associated policies are also resurrected as part of https://github.com/firezone/firezone/issues/8187
    end

    test "persists the sync error on the provider", %{provider: provider} do
      error_message =
        "Admin SDK API has not been used in project XXXX before or it is disabled. " <>
          "Enable it by visiting https://console.developers.google.com/apis/api/admin.googleapis.com/overview?project=XXXX " <>
          "then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry."

      response = %{
        "error" => %{
          "code" => 403,
          "message" => error_message,
          "errors" => [
            %{
              "message" => error_message,
              "domain" => "usageLimits",
              "reason" => "accessNotConfigured",
              "extendedHelp" => "https://console.developers.google.com"
            }
          ],
          "status" => "PERMISSION_DENIED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.Help",
              "links" => [
                %{
                  "description" => "Google developers console API activation",
                  "url" =>
                    "https://console.developers.google.com/apis/api/admin.googleapis.com/overview?project=100421656358"
                }
              ]
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "SERVICE_DISABLED",
              "domain" => "googleapis.com",
              "metadata" => %{
                "service" => "admin.googleapis.com",
                "consumer" => "projects/100421656358"
              }
            }
          ]
        }
      }

      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)

      for path <- [
            "/admin/directory/v1/users",
            "/admin/directory/v1/customer/my_customer/orgunits",
            "/admin/directory/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 403, Jason.encode!(response))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1
      assert updated_provider.last_sync_error == error_message
      refute updated_provider.sync_disabled_at

      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      for path <- [
            "/admin/directory/v1/users",
            "/admin/directory/v1/customer/my_customer/orgunits",
            "/admin/directory/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 500, "")
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 2
      assert updated_provider.last_sync_error == "Google API is temporarily unavailable"

      cancel_bypass_expectations_check(bypass)
    end

    test "disables the sync on 401 response code", %{account: account, provider: provider} do
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      GoogleWorkspaceDirectory.mock_token_endpoint(bypass)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      _identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      error_message =
        "Admin SDK API has not been used in project XXXX before or it is disabled. " <>
          "Enable it by visiting https://console.developers.google.com/apis/api/admin.googleapis.com/overview?project=XXXX " <>
          "then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry."

      response = %{
        "error" => %{
          "code" => 401,
          "message" => error_message,
          "errors" => [
            %{
              "message" => error_message,
              "domain" => "usageLimits",
              "reason" => "accessNotConfigured",
              "extendedHelp" => "https://console.developers.google.com"
            }
          ],
          "status" => "PERMISSION_DENIED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.Help",
              "links" => [
                %{
                  "description" => "Google developers console API activation",
                  "url" =>
                    "https://console.developers.google.com/apis/api/admin.googleapis.com/overview?project=100421656358"
                }
              ]
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "SERVICE_DISABLED",
              "domain" => "googleapis.com",
              "metadata" => %{
                "service" => "admin.googleapis.com",
                "consumer" => "projects/100421656358"
              }
            }
          ]
        }
      }

      for path <- [
            "/admin/directory/v1/users",
            "/admin/directory/v1/customer/my_customer/orgunits",
            "/admin/directory/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 401, Jason.encode!(response))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1
      assert updated_provider.last_sync_error == error_message
      assert updated_provider.sync_disabled_at

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Identity Provider Sync Error"
        assert email.text_body =~ "failed to sync 1 time(s)"
      end)

      cancel_bypass_expectations_check(bypass)
    end

    test "sends email on failed directory sync", %{account: account, provider: provider} do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      _identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      error_message =
        "Admin SDK API has not been used in project XXXX before or it is disabled. " <>
          "Enable it by visiting https://console.developers.google.com/apis/api/admin.googleapis.com/overview?project=XXXX " <>
          "then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry."

      response = %{
        "error" => %{
          "code" => 403,
          "message" => error_message,
          "errors" => [
            %{
              "message" => error_message,
              "domain" => "usageLimits",
              "reason" => "accessNotConfigured",
              "extendedHelp" => "https://console.developers.google.com"
            }
          ],
          "status" => "PERMISSION_DENIED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.Help",
              "links" => [
                %{
                  "description" => "Google developers console API activation",
                  "url" =>
                    "https://console.developers.google.com/apis/api/admin.googleapis.com/overview?project=100421656358"
                }
              ]
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "SERVICE_DISABLED",
              "domain" => "googleapis.com",
              "metadata" => %{
                "service" => "admin.googleapis.com",
                "consumer" => "projects/100421656358"
              }
            }
          ]
        }
      }

      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      for path <- [
            "/admin/directory/v1/users",
            "/admin/directory/v1/customer/my_customer/orgunits",
            "/admin/directory/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 403, Jason.encode!(response))
        end)
      end

      provider
      |> Ecto.Changeset.change(last_syncs_failed: 9)
      |> Repo.update!()

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Identity Provider Sync Error"
        assert email.text_body =~ "failed to sync 10 time(s)"
      end)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      refute_email_sent()

      cancel_bypass_expectations_check(bypass)
    end
  end
end
