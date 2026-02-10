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

      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      # Mock all requests
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{
              "access_token" => "test_token",
              "token_type" => "Bearer",
              "expires_in" => 3600
            })

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [
                    %{"id" => @test_service_principal_id, "appId" => directory_sync_client_id}
                  ]
                })

              String.contains?(filter, auth_provider_client_id) ->
                # Auth provider not found (deprecated)
                Req.Test.json(conn, %{"value" => []})

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "appRoleAssignedTo") ->
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

          String.ends_with?(path, "/$batch") ->
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

          String.contains?(path, "transitiveMembers") ->
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

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
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

      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      # Mock all requests
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{"value" => [%{"id" => @test_service_principal_id}]})

              String.contains?(filter, auth_provider_client_id) ->
                Req.Test.json(conn, %{"value" => []})

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "appRoleAssignedTo") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "user_123",
                  "principalType" => "User",
                  "principalDisplayName" => "Test User"
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
                    "id" => "user_123",
                    "displayName" => "Test User",
                    "mail" => nil,
                    "userPrincipalName" => "testuser@example.onmicrosoft.com"
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

      # Identity should use userPrincipalName as email
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "testuser@example.onmicrosoft.com"
    end

    test "handles batch user fetch with partial failures gracefully" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      # Mock all requests
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{"value" => [%{"id" => @test_service_principal_id}]})

              String.contains?(filter, auth_provider_client_id) ->
                Req.Test.json(conn, %{"value" => []})

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "appRoleAssignedTo") ->
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

          String.ends_with?(path, "/$batch") ->
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

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
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

    test "syncs assignments from both directory sync and auth provider apps" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Get the expected client_ids from config
      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      # Track which client_ids were used in service principal lookups
      test_pid = self()

      directory_sync_sp_id = "sp_directory_sync"
      auth_provider_sp_id = "sp_auth_provider"

      # Mock all requests
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            # Capture the filter to verify which client_id was looked up
            params = URI.decode_query(query)
            filter = params["$filter"]
            send(test_pid, {:service_principal_lookup, filter})

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [
                    %{"id" => directory_sync_sp_id, "appId" => directory_sync_client_id}
                  ]
                })

              String.contains?(filter, auth_provider_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [%{"id" => auth_provider_sp_id, "appId" => auth_provider_client_id}]
                })

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "#{directory_sync_sp_id}/appRoleAssignedTo") ->
            # Directory sync app has a user assignment
            send(test_pid, {:app_role_query, :directory_sync})

            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "user_dir_sync_123",
                  "principalType" => "User",
                  "principalDisplayName" => "Directory Sync User"
                }
              ]
            })

          String.contains?(path, "#{auth_provider_sp_id}/appRoleAssignedTo") ->
            # Auth provider app also has a user assignment (deprecated, for backwards compat)
            send(test_pid, {:app_role_query, :auth_provider})

            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "user_auth_123",
                  "principalType" => "User",
                  "principalDisplayName" => "Auth Provider User"
                }
              ]
            })

          String.ends_with?(path, "/$batch") ->
            # Return user details based on which user IDs are requested
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            request_body = Jason.decode!(body)

            responses =
              Enum.map(request_body["requests"], fn req ->
                cond do
                  String.contains?(req["url"], "user_dir_sync_123") ->
                    %{
                      "id" => req["id"],
                      "status" => 200,
                      "body" => %{
                        "id" => "user_dir_sync_123",
                        "displayName" => "Directory Sync User",
                        "mail" => "dirsync@example.com",
                        "userPrincipalName" => "dirsync@example.com"
                      }
                    }

                  String.contains?(req["url"], "user_auth_123") ->
                    %{
                      "id" => req["id"],
                      "status" => 200,
                      "body" => %{
                        "id" => "user_auth_123",
                        "displayName" => "Auth Provider User",
                        "mail" => "authprovider@example.com",
                        "userPrincipalName" => "authprovider@example.com"
                      }
                    }

                  true ->
                    %{"id" => req["id"], "status" => 404, "body" => %{"error" => "not found"}}
                end
              end)

            Req.Test.json(conn, %{"responses" => responses})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify both service principals were looked up
      lookups = receive_all_messages(:service_principal_lookup)
      assert length(lookups) == 2
      assert Enum.any?(lookups, &String.contains?(&1, directory_sync_client_id))
      assert Enum.any?(lookups, &String.contains?(&1, auth_provider_client_id))

      # Verify both apps were queried for assignments
      app_role_queries = receive_all_messages(:app_role_query)
      assert :directory_sync in app_role_queries
      assert :auth_provider in app_role_queries

      # Verify users from BOTH apps were synced
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 2
      identity_emails = Enum.map(identities, & &1.email) |> Enum.sort()
      assert identity_emails == ["authprovider@example.com", "dirsync@example.com"]
    end

    test "syncs groups and their members from both directory sync and auth provider apps" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Get the expected client_ids from config
      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      directory_sync_sp_id = "sp_directory_sync"
      auth_provider_sp_id = "sp_auth_provider"

      # Mock all requests
      Req.Test.expect(APIClient, 30, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [
                    %{"id" => directory_sync_sp_id, "appId" => directory_sync_client_id}
                  ]
                })

              String.contains?(filter, auth_provider_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [%{"id" => auth_provider_sp_id, "appId" => auth_provider_client_id}]
                })

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "#{directory_sync_sp_id}/appRoleAssignedTo") ->
            # Directory sync app has a GROUP assignment
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "group_engineering_123",
                  "principalType" => "Group",
                  "principalDisplayName" => "Engineering Team"
                }
              ]
            })

          String.contains?(path, "#{auth_provider_sp_id}/appRoleAssignedTo") ->
            # Auth provider app also has a GROUP assignment (deprecated, for backwards compat)
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "group_sales_123",
                  "principalType" => "Group",
                  "principalDisplayName" => "Sales Team"
                }
              ]
            })

          # Transitive members for Engineering Team (from directory sync app)
          String.contains?(path, "group_engineering_123/transitiveMembers") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "@odata.type" => "#microsoft.graph.user",
                  "id" => "user_alice_123",
                  "displayName" => "Alice Engineer",
                  "mail" => "alice@example.com",
                  "userPrincipalName" => "alice@example.com",
                  "givenName" => "Alice",
                  "surname" => "Engineer"
                },
                %{
                  "@odata.type" => "#microsoft.graph.user",
                  "id" => "user_bob_123",
                  "displayName" => "Bob Engineer",
                  "mail" => "bob@example.com",
                  "userPrincipalName" => "bob@example.com",
                  "givenName" => "Bob",
                  "surname" => "Engineer"
                }
              ]
            })

          # Transitive members for Sales Team (from auth provider app)
          String.contains?(path, "group_sales_123/transitiveMembers") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "@odata.type" => "#microsoft.graph.user",
                  "id" => "user_carol_123",
                  "displayName" => "Carol Sales",
                  "mail" => "carol@example.com",
                  "userPrincipalName" => "carol@example.com",
                  "givenName" => "Carol",
                  "surname" => "Sales"
                }
              ]
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify BOTH groups were created
      groups = Repo.all(Group)
      assert length(groups) == 2
      group_names = Enum.map(groups, & &1.name) |> Enum.sort()
      assert group_names == ["Engineering Team", "Sales Team"]

      # Verify members from BOTH groups were synced as identities
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 3
      identity_emails = Enum.map(identities, & &1.email) |> Enum.sort()
      assert identity_emails == ["alice@example.com", "bob@example.com", "carol@example.com"]

      # Verify memberships were created
      memberships = Repo.all(Membership)
      assert length(memberships) == 3

      # Verify Engineering Team has 2 members (Alice and Bob)
      engineering_group = Enum.find(groups, &(&1.name == "Engineering Team"))
      engineering_memberships = Enum.filter(memberships, &(&1.group_id == engineering_group.id))
      assert length(engineering_memberships) == 2

      # Verify Sales Team has 1 member (Carol)
      sales_group = Enum.find(groups, &(&1.name == "Sales Team"))
      sales_memberships = Enum.filter(memberships, &(&1.group_id == sales_group.id))
      assert length(sales_memberships) == 1
    end

    test "syncs users from auth provider app when directory sync app has no assignments (deprecated)" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      # Get the expected client_ids from config
      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      directory_sync_sp_id = "sp_directory_sync"
      auth_provider_sp_id = "sp_auth_provider"

      # Mock all requests
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [
                    %{"id" => directory_sync_sp_id, "appId" => directory_sync_client_id}
                  ]
                })

              String.contains?(filter, auth_provider_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [%{"id" => auth_provider_sp_id, "appId" => auth_provider_client_id}]
                })

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "#{directory_sync_sp_id}/appRoleAssignedTo") ->
            # Directory sync app has NO assignments
            Req.Test.json(conn, %{"value" => []})

          String.contains?(path, "#{auth_provider_sp_id}/appRoleAssignedTo") ->
            # Auth provider app HAS assignments
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "user_legacy_123",
                  "principalType" => "User",
                  "principalDisplayName" => "Legacy User"
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
                    "id" => "user_legacy_123",
                    "displayName" => "Legacy User",
                    "mail" => "legacy@example.com",
                    "userPrincipalName" => "legacy@example.com"
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

      # Verify user from auth provider was synced
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "legacy@example.com"
    end

    test "handles case when neither directory sync nor auth provider apps have assignments" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      directory_sync_sp_id = "sp_directory_sync"
      auth_provider_sp_id = "sp_auth_provider"

      # Mock all requests
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [
                    %{"id" => directory_sync_sp_id, "appId" => directory_sync_client_id}
                  ]
                })

              String.contains?(filter, auth_provider_client_id) ->
                Req.Test.json(conn, %{
                  "value" => [%{"id" => auth_provider_sp_id, "appId" => auth_provider_client_id}]
                })

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "appRoleAssignedTo") ->
            # Neither app has assignments
            Req.Test.json(conn, %{"value" => []})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Perform sync - should complete successfully with no data
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # No identities should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "fails sync when Directory Sync service principal not found (consent revoked)" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      # Mock access token and service principal lookup returning empty for directory sync
      Req.Test.expect(APIClient, 10, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            if String.contains?(filter, directory_sync_client_id) do
              # Directory Sync app NOT found - consent was revoked
              Req.Test.json(conn, %{"value" => []})
            else
              Req.Test.json(conn, %{"value" => []})
            end

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError with appropriate step
      error =
        assert_raise Portal.Entra.SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :fetch_directory_sync_service_principal
      assert {:consent_revoked, msg} = error.error
      assert msg =~ "Directory Sync app service principal not found"
    end

    test "continues sync when Auth Provider service principal not found (deprecated app)" do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account, sync_all_groups: false)

      api_client_config = Application.get_env(:portal, Portal.Entra.APIClient)
      directory_sync_client_id = api_client_config[:client_id]

      auth_provider_config = Application.get_env(:portal, Portal.Entra.AuthProvider)
      auth_provider_client_id = auth_provider_config[:client_id]

      directory_sync_sp_id = "sp_directory_sync"

      # Mock requests - directory sync found, auth provider NOT found
      Req.Test.expect(APIClient, 20, fn %{request_path: path, query_string: query} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          path == "/v1.0/servicePrincipals" ->
            params = URI.decode_query(query)
            filter = params["$filter"]

            cond do
              String.contains?(filter, directory_sync_client_id) ->
                # Directory Sync app IS found
                Req.Test.json(conn, %{
                  "value" => [
                    %{"id" => directory_sync_sp_id, "appId" => directory_sync_client_id}
                  ]
                })

              String.contains?(filter, auth_provider_client_id) ->
                # Auth Provider app NOT found (deprecated, should be ok)
                Req.Test.json(conn, %{"value" => []})

              true ->
                Req.Test.json(conn, %{"value" => []})
            end

          String.contains?(path, "#{directory_sync_sp_id}/appRoleAssignedTo") ->
            Req.Test.json(conn, %{
              "value" => [
                %{
                  "principalId" => "user_123",
                  "principalType" => "User",
                  "principalDisplayName" => "Test User"
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
                    "id" => "user_123",
                    "displayName" => "Test User",
                    "mail" => "test@example.com",
                    "userPrincipalName" => "test@example.com"
                  }
                }
              ]
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should complete successfully even though auth provider app is not found
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # User should be synced from directory sync app
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "test@example.com"
    end
  end

  # Helper to receive all messages of a given type
  defp receive_all_messages(tag, acc \\ []) do
    receive do
      {^tag, value} -> receive_all_messages(tag, acc ++ [value])
    after
      0 -> acc
    end
  end
end
