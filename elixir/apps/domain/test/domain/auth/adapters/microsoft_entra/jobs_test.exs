defmodule Domain.Auth.Adapters.MicrosoftEntra.JobsTest do
  use Domain.DataCase, async: true
  alias Domain.{Auth, Actors}
  alias Domain.Mocks.MicrosoftEntraDirectory
  import Domain.Auth.Adapters.MicrosoftEntra.Jobs

  describe "refresh_access_tokens/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_microsoft_entra_provider(account: account)

      provider =
        Domain.Fixture.update!(provider, %{
          adapter_state: %{
            "access_token" => "OIDC_ACCESS_TOKEN",
            "refresh_token" => "OIDC_REFRESH_TOKEN",
            "expires_at" => DateTime.utc_now() |> DateTime.add(15, :minute),
            "claims" => "openid email profile offline_access"
          }
        })

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        identity: identity
      }
    end

    test "refreshes the access token", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      {token, claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "OTHER_REFRESH_TOKEN",
        "expires_in" => nil
      })

      Mocks.OpenIDConnect.expect_userinfo(bypass)

      assert refresh_access_tokens(%{}) == :ok

      provider = Repo.get!(Domain.Auth.Provider, provider.id)

      assert %{
               "access_token" => "MY_ACCESS_TOKEN",
               "claims" => ^claims,
               "expires_at" => expires_at,
               "refresh_token" => "OIDC_REFRESH_TOKEN",
               "userinfo" => %{
                 "email" => "ada@example.com",
                 "email_verified" => true,
                 "family_name" => "Lovelace",
                 "given_name" => "Ada",
                 "locale" => "en",
                 "name" => "Ada Lovelace",
                 "picture" =>
                   "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg",
                 "sub" => "353690423699814251281"
               }
             } = provider.adapter_state

      assert expires_at
    end

    test "does not crash when endpoint it not available", %{
      bypass: bypass
    } do
      Bypass.down(bypass)
      assert refresh_access_tokens(%{}) == :ok
    end
  end

  describe "sync_directory/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_microsoft_entra_provider(account: account)

      %{
        bypass: bypass,
        account: account,
        provider: provider
      }
    end

    test "syncs IdP data", %{provider: provider} do
      bypass = Bypass.open()

      groups = [
        %{"id" => "GROUP_ALL_ID", "displayName" => "All"},
        %{"id" => "GROUP_ENGINEERING_ID", "displayName" => "Engineering"}
      ]

      users = [
        %{
          "id" => "USER_JDOE_ID",
          "displayName" => "John Doe",
          "givenName" => "John",
          "surname" => "Doe",
          "userPrincipalName" => "jdoe@example.local",
          "mail" => "jdoe@example.local",
          "accountEnabled" => true
        },
        %{
          "id" => "USER_JSMITH_ID",
          "displayName" => "Jane Smith",
          "givenName" => "Jane",
          "surname" => "Smith",
          "userPrincipalName" => "jsmith@example.local",
          "mail" => "jsmith@example.local",
          "accountEnabled" => true
        }
      ]

      members = [
        %{
          "id" => "USER_JDOE_ID",
          "displayName" => "John Doe",
          "userPrincipalName" => "jdoe@example.local",
          "accountEnabled" => true
        },
        %{
          "id" => "USER_JSMITH_ID",
          "displayName" => "Jane Smith",
          "userPrincipalName" => "jsmith@example.local",
          "accountEnabled" => true
        }
      ]

      MicrosoftEntraDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      MicrosoftEntraDirectory.mock_groups_list_endpoint(bypass, groups)
      MicrosoftEntraDirectory.mock_users_list_endpoint(bypass, users)

      Enum.each(groups, fn group ->
        MicrosoftEntraDirectory.mock_group_members_list_endpoint(bypass, group["id"], members)
      end)

      assert sync_directory(%{}) == :ok

      groups = Actors.Group |> Repo.all()
      assert length(groups) == 2

      for group <- groups do
        assert group.provider_identifier in ["G:GROUP_ALL_ID", "G:GROUP_ENGINEERING_ID"]
        assert group.name in ["Group:All", "Group:Engineering"]

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
        assert identity.provider_identifier in ["USER_JDOE_ID", "USER_JSMITH_ID"]

        assert identity.provider_state in [
                 %{"userinfo" => %{"email" => "jdoe@example.local"}},
                 %{"userinfo" => %{"email" => "jsmith@example.local"}}
               ]

        assert identity.actor.name in ["John Doe", "Jane Smith"]
        assert identity.actor.last_synced_at
      end

      memberships = Actors.Membership |> Repo.all()
      assert length(memberships) == 4

      updated_provider = Repo.get!(Domain.Auth.Provider, provider.id)
      assert updated_provider.last_synced_at != provider.last_synced_at
    end

    test "does not crash on endpoint errors" do
      bypass = Bypass.open()
      Bypass.down(bypass)
      MicrosoftEntraDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      assert sync_directory(%{}) == :ok

      assert Repo.aggregate(Actors.Group, :count) == 0
    end

    test "updates existing identities and actors", %{account: account, provider: provider} do
      bypass = Bypass.open()

      users = [
        %{
          "id" => "USER_JDOE_ID",
          "displayName" => "John Doe",
          "givenName" => "John",
          "surname" => "Doe",
          "userPrincipalName" => "jdoe@example.local",
          "mail" => "jdoe@example.local",
          "accountEnabled" => true
        }
      ]

      actor = Fixtures.Actors.create_actor(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
          provider_identifier: "USER_JDOE_ID"
        )

      MicrosoftEntraDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      MicrosoftEntraDirectory.mock_groups_list_endpoint(bypass, [])
      MicrosoftEntraDirectory.mock_users_list_endpoint(bypass, users)

      assert sync_directory(%{}) == :ok

      assert updated_identity =
               Repo.get(Domain.Auth.Identity, identity.id)
               |> Repo.preload(:actor)

      assert updated_identity.provider_state == %{
               "userinfo" => %{"email" => "jdoe@example.local"}
             }

      assert updated_identity.actor.name == "John Doe"
      assert updated_identity.actor.last_synced_at
    end

    test "updates existing groups and memberships", %{account: account, provider: provider} do
      bypass = Bypass.open()

      users = [
        %{
          "id" => "USER_JDOE_ID",
          "displayName" => "John Doe",
          "givenName" => "John",
          "surname" => "Doe",
          "userPrincipalName" => "jdoe@example.local",
          "mail" => "jdoe@example.local",
          "accountEnabled" => true
        },
        %{
          "id" => "USER_JSMITH_ID",
          "displayName" => "Jane Smith",
          "givenName" => "Jane",
          "surname" => "Smith",
          "userPrincipalName" => "jsmith@example.local",
          "mail" => "jsmith@example.local",
          "accountEnabled" => true
        }
      ]

      groups = [
        %{"id" => "GROUP_ALL_ID", "displayName" => "All"},
        %{"id" => "GROUP_ENGINEERING_ID", "displayName" => "Engineering"}
      ]

      one_member = [
        %{
          "id" => "USER_JDOE_ID",
          "displayName" => "John Doe",
          "userPrincipalName" => "jdoe@example.local",
          "accountEnabled" => true
        }
      ]

      two_members =
        one_member ++
          [
            %{
              "id" => "USER_JSMITH_ID",
              "displayName" => "Jane Smith",
              "userPrincipalName" => "jsmith@example.local",
              "accountEnabled" => true
            }
          ]

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: "USER_JDOE_ID"
      )

      other_actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: other_actor,
        provider_identifier: "USER_JSMITH_ID"
      )

      deleted_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: other_actor,
          provider_identifier: "USER_JSMITH_ID2"
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
          provider_identifier: "G:GROUP_ALL_ID"
        )

      deleted_group =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:DELETED_GROUP_ID!"
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

      :ok = Domain.Actors.subscribe_to_membership_updates_for_actor(actor)
      :ok = Domain.Actors.subscribe_to_membership_updates_for_actor(other_actor)
      :ok = Domain.Actors.subscribe_to_membership_updates_for_actor(deleted_membership.actor_id)
      :ok = Domain.Policies.subscribe_to_events_for_actor(actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor(other_actor)
      :ok = Domain.Policies.subscribe_to_events_for_actor_group(deleted_group)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(deleted_group_flow)
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(deleted_identity_flow)
      :ok = Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{deleted_identity_token.id}")

      MicrosoftEntraDirectory.mock_groups_list_endpoint(bypass, groups)
      MicrosoftEntraDirectory.mock_users_list_endpoint(bypass, users)

      MicrosoftEntraDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_ALL_ID",
        two_members
      )

      MicrosoftEntraDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_ENGINEERING_ID",
        one_member
      )

      assert sync_directory(%{}) == :ok

      assert updated_group = Repo.get(Domain.Actors.Group, group.id)
      assert updated_group.name == "Group:All"

      assert created_group =
               Repo.get_by(Domain.Actors.Group, provider_identifier: "G:GROUP_ENGINEERING_ID")

      assert created_group.name == "Group:Engineering"

      assert memberships = Repo.all(Domain.Actors.Membership.Query.all())
      assert length(memberships) == 4

      assert memberships = Repo.all(Domain.Actors.Membership.Query.with_joined_groups())
      assert length(memberships) == 4

      membership_group_ids = Enum.map(memberships, & &1.group_id)
      assert group.id in membership_group_ids
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

    test "persists the sync error on the provider", %{provider: provider} do
      bypass = Bypass.open()
      MicrosoftEntraDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      error_message = "Lifetime validation failed, the token is expired."

      response = %{
        "error" => %{
          "code" => "InvalidAuthenticationToken",
          "message" => "Lifetime validation failed, the token is expired.",
          "innerError" => %{
            "date" => "2024-02-02T19:22:43",
            "request-id" => "db39f8ea-8072-4eb5-95e2-26b8f78c1673",
            "client-request-id" => "db39f8ea-8072-4eb5-95e2-26b8f78c1673"
          }
        }
      }

      Bypass.expect_once(bypass, "GET", "v1.0/users", fn conn ->
        Plug.Conn.send_resp(conn, 401, Jason.encode!(response))
      end)

      assert sync_directory(%{}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1
      assert updated_provider.last_sync_error == error_message

      Bypass.expect_once(bypass, "GET", "v1.0/users", fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert sync_directory(%{}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 2
      assert updated_provider.last_sync_error == "Microsoft Graph API is temporarily unavailable"
    end
  end
end
