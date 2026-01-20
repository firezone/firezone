defmodule Portal.Entra.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.Entra.APIClient
  alias Portal.Entra.Sync
  alias Portal.ExternalIdentity
  alias Portal.Group
  alias Portal.Membership
  alias Portal.Actor

  @test_service_principal_id "sp_12345"

  describe "perform/1" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "performs successful sync with assigned groups mode (sync_all_groups: false)" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Mock access token
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{
            "access_token" => "test_token",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected request"})
        end
      end)

      # Mock service principal lookup
      Req.Test.expect(APIClient, fn %{request_path: "/v1.0/servicePrincipals"} = conn ->
        Req.Test.json(conn, %{
          "value" => [
            %{"id" => @test_service_principal_id, "appId" => "test_client_id"}
          ]
        })
      end)

      # Mock app role assignments (1 user, 1 group)
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.contains?(path, "appRoleAssignedTo") do
          Req.Test.json(conn, %{
            "value" => [
              %{
                "id" => "assignment1",
                "principalId" => "user_direct_123",
                "principalType" => "User",
                "principalDisplayName" => "Direct User"
              },
              %{
                "id" => "assignment2",
                "principalId" => "group_eng_123",
                "principalType" => "Group",
                "principalDisplayName" => "Engineering"
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock batch get users for direct user assignment
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/$batch") do
          Req.Test.json(conn, %{
            "responses" => [
              %{
                "id" => "1",
                "status" => 200,
                "body" => %{
                  "id" => "user_direct_123",
                  "displayName" => "Direct User",
                  "mail" => "direct@example.com",
                  "userPrincipalName" => "direct@example.com",
                  "givenName" => "Direct",
                  "surname" => "User"
                }
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock group transitive members
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.contains?(path, "transitiveMembers") do
          Req.Test.json(conn, %{
            "value" => [
              %{
                "@odata.type" => "#microsoft.graph.user",
                "id" => "user_alice_123",
                "displayName" => "Alice Smith",
                "mail" => "alice@example.com",
                "userPrincipalName" => "alice@example.com",
                "givenName" => "Alice",
                "surname" => "Smith"
              },
              %{
                "@odata.type" => "#microsoft.graph.user",
                "id" => "user_bob_123",
                "displayName" => "Bob Jones",
                "mail" => "bob@example.com",
                "userPrincipalName" => "bob@example.com"
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify identities created (3 total: 1 direct user + 2 group members)
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 3

      identity_emails = Enum.map(identities, & &1.email) |> Enum.sort()

      assert identity_emails == [
               "alice@example.com",
               "bob@example.com",
               "direct@example.com"
             ]

      # Verify group created
      groups = Repo.all(Group)
      assert length(groups) == 1
      group = hd(groups)
      assert group.name == "Engineering"
      assert group.idp_id == "group_eng_123"

      # Verify memberships created (2 memberships for the 2 group members)
      memberships = Repo.all(Membership)
      assert length(memberships) == 2

      # Verify directory updated with sync timestamp
      updated_directory = Repo.get(Portal.Entra.Directory, directory.id)
      refute is_nil(updated_directory.synced_at)
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
    end

    test "performs successful sync with all groups mode (sync_all_groups: true)" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: true)

      # Mock all requests with unlimited calls
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{
              "access_token" => "test_token",
              "token_type" => "Bearer",
              "expires_in" => 3600
            })

          path == "/v1.0/groups" ->
            Req.Test.json(conn, %{
              "value" => [
                %{"id" => "group_sales_123", "displayName" => "Sales Team"},
                %{"id" => "group_eng_123", "displayName" => "Engineering"}
              ]
            })

          String.contains?(path, "group_sales_123/transitiveMembers") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "@odata.type" => "#microsoft.graph.user",
                  "id" => "user_carol_123",
                  "displayName" => "Carol Davis",
                  "mail" => "carol@example.com",
                  "userPrincipalName" => "carol@example.com"
                }
              ]
            })

          String.contains?(path, "group_eng_123/transitiveMembers") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "@odata.type" => "#microsoft.graph.user",
                  "id" => "user_dave_123",
                  "displayName" => "Dave Wilson",
                  "mail" => "dave@example.com",
                  "userPrincipalName" => "dave@example.com"
                }
              ]
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify identities created (2 users)
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 2

      identity_emails = Enum.map(identities, & &1.email) |> Enum.sort()
      assert identity_emails == ["carol@example.com", "dave@example.com"]

      # Verify groups created (2 groups)
      groups = Repo.all(Group)
      assert length(groups) == 2
      group_names = Enum.map(groups, & &1.name) |> Enum.sort()
      assert group_names == ["Engineering", "Sales Team"]

      # Verify memberships created (2 memberships)
      memberships = Repo.all(Membership)
      assert length(memberships) == 2
    end

    test "handles missing directory gracefully" do
      non_existent_id = Ecto.UUID.generate()

      # Should not raise an error
      assert :ok = perform_job(Sync, %{directory_id: non_existent_id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "handles disabled directory" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, is_disabled: true)

      # Should not perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "handles disabled account" do
      account = account_fixture(features: %{idp_sync: true})

      account =
        account
        |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
        |> Repo.update!()

      directory = entra_directory_fixture(account: account)

      # Should not perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "deletes unsynced identities on subsequent sync" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Create an old identity that won't be in the new sync
      issuer = "https://login.microsoftonline.com/#{directory.tenant_id}/v2.0"
      old_synced_at = DateTime.utc_now() |> DateTime.add(-3600, :second)

      actor =
        Repo.insert!(%Actor{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          type: :account_user,
          name: "Old User",
          email: "old@example.com",
          created_by_directory_id: directory.id
        })

      old_identity =
        Repo.insert!(%ExternalIdentity{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          actor_id: actor.id,
          issuer: issuer,
          idp_id: "old_user_123",
          directory_id: directory.id,
          email: "old@example.com",
          name: "Old User",
          last_synced_at: old_synced_at
        })

      # Mock successful sync with a different user
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            Req.Test.json(conn, %{"value" => [%{"id" => @test_service_principal_id}]})

          String.contains?(path, "appRoleAssignedTo") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "new_user_123",
                  "principalType" => "User",
                  "principalDisplayName" => "New User"
                }
              ]
            })

          String.ends_with?(path, "/$batch") ->
            Req.Test.json(conn, %{
              "responses" => [
                %{
                  "id" => "1",
                  "status" => 200,
                  "body" => %{
                    "id" => "new_user_123",
                    "displayName" => "New User",
                    "mail" => "new@example.com",
                    "userPrincipalName" => "new@example.com"
                  }
                }
              ]
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Old identity should be deleted
      refute Repo.get_by(ExternalIdentity, id: old_identity.id)

      # Old actor should be deleted (no other identities)
      refute Repo.get_by(Actor, id: actor.id)

      # New identity should exist
      new_identities = Repo.all(ExternalIdentity)
      assert length(new_identities) == 1
      assert hd(new_identities).email == "new@example.com"
    end

    test "deletes unsynced groups on subsequent sync" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: true)

      # Create an old group that won't be in the new sync
      old_synced_at = DateTime.utc_now() |> DateTime.add(-3600, :second)

      old_group =
        Repo.insert!(%Group{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          directory_id: directory.id,
          idp_id: "old_group_123",
          name: "Old Group",
          type: :static,
          last_synced_at: old_synced_at
        })

      # Mock successful sync with a different group
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/groups" ->
            Req.Test.json(conn, %{
              "value" => [
                %{"id" => "new_group_123", "displayName" => "New Group"}
              ]
            })

          String.contains?(path, "transitiveMembers") ->
            Req.Test.json(conn, %{"value" => []})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Old group should be deleted
      refute Repo.get_by(Group, id: old_group.id)

      # New group should exist
      new_groups = Repo.all(Group)
      assert length(new_groups) == 1
      assert hd(new_groups).name == "New Group"
    end

    test "filters out non-user members from group transitive members" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: true)

      # Mock all requests with unlimited calls
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/groups" ->
            Req.Test.json(conn, %{
              "value" => [%{"id" => "group_123", "displayName" => "Test Group"}]
            })

          String.contains?(path, "transitiveMembers") ->
            Req.Test.json(conn, %{
              "value" => [
                # This user should be included
                %{
                  "@odata.type" => "#microsoft.graph.user",
                  "id" => "user_123",
                  "displayName" => "Test User",
                  "mail" => "user@example.com",
                  "userPrincipalName" => "user@example.com"
                },
                # This group should be filtered out
                %{
                  "@odata.type" => "#microsoft.graph.group",
                  "id" => "nested_group_123",
                  "displayName" => "Nested Group"
                },
                # This service principal should be filtered out
                %{
                  "@odata.type" => "#microsoft.graph.servicePrincipal",
                  "id" => "sp_123",
                  "displayName" => "Service Principal"
                }
              ]
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Only the user identity should be created
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "user@example.com"
    end

    test "uses userPrincipalName as fallback when mail is null" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Mock access token
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "test_token"})
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock service principal
      Req.Test.expect(APIClient, fn %{request_path: "/v1.0/servicePrincipals"} = conn ->
        Req.Test.json(conn, %{"value" => [%{"id" => @test_service_principal_id}]})
      end)

      # Mock app role assignment
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.contains?(path, "appRoleAssignedTo") do
          Req.Test.json(conn, %{
            "value" => [
              %{
                "principalId" => "user_123",
                "principalType" => "User",
                "principalDisplayName" => "Test User"
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock batch get user with null mail
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/$batch") do
          Req.Test.json(conn, %{
            "responses" => [
              %{
                "id" => "1",
                "status" => 200,
                "body" => %{
                  "id" => "user_123",
                  "displayName" => "Test User",
                  "mail" => nil,
                  "userPrincipalName" => "testuser@example.onmicrosoft.com"
                }
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Identity should use userPrincipalName as email
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "testuser@example.onmicrosoft.com"
    end

    test "handles batch user fetch with partial failures gracefully" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Mock access token
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "test_token"})
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock service principal
      Req.Test.expect(APIClient, fn %{request_path: "/v1.0/servicePrincipals"} = conn ->
        Req.Test.json(conn, %{"value" => [%{"id" => @test_service_principal_id}]})
      end)

      # Mock app role assignments with 2 users
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.contains?(path, "appRoleAssignedTo") do
          Req.Test.json(conn, %{
            "value" => [
              %{
                "principalId" => "user1_123",
                "principalType" => "User",
                "principalDisplayName" => "User One"
              },
              %{
                "principalId" => "user2_123",
                "principalType" => "User",
                "principalDisplayName" => "User Two"
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock batch with one success and one failure
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/$batch") do
          Req.Test.json(conn, %{
            "responses" => [
              %{
                "id" => "1",
                "status" => 200,
                "body" => %{
                  "id" => "user1_123",
                  "displayName" => "User One",
                  "mail" => "user1@example.com",
                  "userPrincipalName" => "user1@example.com"
                }
              },
              %{
                "id" => "2",
                "status" => 404,
                "body" => %{"error" => "User not found"}
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Only the successful user should be synced
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "user1@example.com"
    end

    test "clears error state on successful sync" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        entra_directory_fixture(
          account: account,
          sync_all_groups: true,
          error_message: "Previous error",
          error_email_count: 3,
          errored_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
        )

      # Mock successful sync
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/groups" ->
            Req.Test.json(conn, %{"value" => []})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Error state should be cleared
      updated_directory = Repo.get(Portal.Entra.Directory, directory.id)
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
      assert updated_directory.errored_at == nil
      assert updated_directory.is_disabled == false
      assert updated_directory.disabled_reason == nil
      refute is_nil(updated_directory.synced_at)
    end

    test "validates app role assignments have required fields" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Mock access token
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "test_token"})
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock service principal
      Req.Test.expect(APIClient, fn %{request_path: "/v1.0/servicePrincipals"} = conn ->
        Req.Test.json(conn, %{"value" => [%{"id" => @test_service_principal_id}]})
      end)

      # Mock app role assignments with missing principalId
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.contains?(path, "appRoleAssignedTo") do
          Req.Test.json(conn, %{
            "value" => [
              %{
                "principalType" => "User",
                "principalDisplayName" => "User Without ID"
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Should raise SyncError
      assert_raise Portal.Entra.SyncError, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "validates users have required id field" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: true)

      # Mock access token
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "test_token"})
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock groups
      Req.Test.expect(APIClient, fn %{request_path: "/v1.0/groups"} = conn ->
        Req.Test.json(conn, %{
          "value" => [%{"id" => "group_123", "displayName" => "Test Group"}]
        })
      end)

      # Mock transitive members with user missing id
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.contains?(path, "transitiveMembers") do
          Req.Test.json(conn, %{
            "value" => [
              %{
                "@odata.type" => "#microsoft.graph.user",
                "displayName" => "User Without ID",
                "mail" => "user@example.com"
              }
            ]
          })
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Should raise SyncError
      assert_raise Portal.Entra.SyncError, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "validates groups have required fields" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: true)

      # Mock access token
      Req.Test.expect(APIClient, fn %{request_path: path} = conn ->
        if String.ends_with?(path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "test_token"})
        else
          Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      # Mock groups with missing displayName
      Req.Test.expect(APIClient, fn %{request_path: "/v1.0/groups"} = conn ->
        Req.Test.json(conn, %{
          "value" => [%{"id" => "group_123"}]
        })
      end)

      # Should raise SyncError
      assert_raise Portal.Entra.SyncError, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end
  end
end
