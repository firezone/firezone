defmodule Domain.Auth.Adapters.GoogleWorkspace.JobsTest do
  use Domain.DataCase, async: true
  alias Domain.{Auth, Actors}
  alias Domain.Mocks.GoogleWorkspaceDirectory
  import Domain.Auth.Adapters.GoogleWorkspace.Jobs

  describe "refresh_access_tokens/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

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
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => nil
      })

      Mocks.OpenIDConnect.expect_userinfo(bypass)

      assert refresh_access_tokens(%{}) == :ok

      provider = Repo.get!(Domain.Auth.Provider, provider.id)

      assert %{
               "access_token" => "MY_ACCESS_TOKEN",
               "claims" => ^claims,
               "expires_at" => expires_at,
               "refresh_token" => "MY_REFRESH_TOKEN",
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
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

      %{
        bypass: bypass,
        account: account,
        provider: provider
      }
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
          "orgUnitPath" => "/Engineering",
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
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, groups)
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, organization_units)
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, users)

      Enum.each(groups, fn group ->
        GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, group["id"], members)
      end)

      assert sync_directory(%{}) == :ok

      groups = Actors.Group |> Repo.all()
      assert length(groups) == 2

      for group <- groups do
        assert group.provider_identifier in ["G:GROUP_ID1", "OU:OU_ID1"]
        assert group.name in ["OrgUnit:Engineering", "Group:Infrastructure"]

        assert group.inserted_at
        assert group.updated_at

        assert group.created_by == :provider
        assert group.provider_id == provider.id
      end

      identities = Auth.Identity |> Repo.all() |> Repo.preload(:actor)
      assert length(identities) == 1

      for identity <- identities do
        assert identity.inserted_at
        assert identity.created_by == :provider
        assert identity.provider_id == provider.id
        assert identity.provider_identifier in ["USER_ID1"]
        assert identity.actor.name in ["Brian Manifold"]
        assert identity.actor.last_synced_at
      end

      memberships = Actors.Membership |> Repo.all()
      assert length(memberships) == 2
      membership_tuples = Enum.map(memberships, &{&1.group_id, &1.actor_id})

      for identity <- identities, group <- groups do
        assert {group.id, identity.actor_id} in membership_tuples
      end
    end

    test "does not crash on endpoint errors" do
      bypass = Bypass.open()
      Bypass.down(bypass)
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")

      assert sync_directory(%{}) == :ok

      assert Repo.aggregate(Actors.Group, :count) == 0
    end
  end
end
