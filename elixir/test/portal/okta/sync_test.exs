defmodule Portal.Okta.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.OktaDirectoryFixtures

  alias Portal.Okta.APIClient
  alias Portal.Okta.Sync
  alias Portal.Okta.SyncError
  alias Portal.ExternalIdentity
  alias Portal.Group
  alias Portal.Membership

  @test_jwk JOSE.JWK.generate_key({:rsa, 1024})
  @test_private_key_jwk @test_jwk |> JOSE.JWK.to_map() |> elem(1)

  # Generate a valid test JWT with required scopes for Okta sync
  @test_access_token (
                       payload = %{
                         "scp" => ["okta.apps.read", "okta.users.read", "okta.groups.read"],
                         "iat" => System.system_time(:second),
                         "exp" => System.system_time(:second) + 3600
                       }

                       {_, jwt} =
                         @test_jwk
                         |> JOSE.JWT.sign(%{"alg" => "RS256"}, payload)
                         |> JOSE.JWS.compact()

                       jwt
                     )

  describe "perform/1" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "performs successful sync with users and groups" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock all API calls
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "profile" => %{
                      "email" => "alice@example.com",
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [
              %{
                "id" => "appgroup_1",
                "_embedded" => %{
                  "group" => %{
                    "id" => "group_123",
                    "profile" => %{"name" => "Engineering"}
                  }
                }
              }
            ])

          String.contains?(path, "/groups/group_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "user_123",
                "status" => "ACTIVE",
                "profile" => %{
                  "email" => "alice@example.com",
                  "firstName" => "Alice",
                  "lastName" => "Smith"
                }
              }
            ])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify identity was created
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "alice@example.com"

      # Verify group was created
      groups = Repo.all(Group)
      assert length(groups) == 1
      assert hd(groups).name == "Engineering"

      # Verify membership was created
      memberships = Repo.all(Membership)
      assert length(memberships) == 1

      # Verify directory was updated with sync timestamp
      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      refute is_nil(updated_directory.synced_at)
      assert updated_directory.error_message == nil
    end

    test "handles missing directory gracefully" do
      non_existent_id = Ecto.UUID.generate()

      assert :ok = perform_job(Sync, %{directory_id: non_existent_id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "handles disabled directory" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          is_disabled: true
        )

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "raises SyncError when user is missing email field" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock API calls with a user missing email
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            # Return user WITHOUT email field
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "profile" => %{
                      # email is missing!
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError with appropriate message
      assert_raise SyncError, ~r/missing 'email' field/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when user email is null" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock API calls with a user having null email
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            # Return user with null email
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "profile" => %{
                      "email" => nil,
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError with appropriate message
      assert_raise SyncError, ~r/missing 'email' field/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when access token fetch fails" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock failed access token request
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      assert_raise SyncError, ~r/get_access_token/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when access token is missing required scopes" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock successful token but introspect returns missing scopes
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            # Only return okta.apps.read - missing users.read and groups.read
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read"
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert_raise SyncError, ~r/scopes: missing.*okta\.users\.read/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when apps fetch fails" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock successful token, failed apps
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error" => "forbidden"})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      assert_raise SyncError, ~r/list_apps/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "clears error state on successful sync" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          error_message: "Previous error",
          error_email_count: 3,
          errored_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
        )

      # Mock successful sync with empty data
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Error state should be cleared
      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
      assert updated_directory.errored_at == nil
      assert updated_directory.is_disabled == false
      refute is_nil(updated_directory.synced_at)
    end
  end

  describe "error handling integration" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "ErrorHandler properly records error when user missing email" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock API calls with a user missing email
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "profile" => %{"firstName" => "Alice", "lastName" => "Smith"}
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Capture the raised exception
      exception =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      # Simulate Oban telemetry error handling
      job = %Oban.Job{
        id: 1,
        args: %{"directory_id" => directory.id},
        worker: "Portal.Okta.Sync",
        queue: "okta_sync",
        meta: %{}
      }

      meta = %{reason: exception, job: job}
      Portal.DirectorySync.ErrorHandler.handle_error(meta)

      # Verify error was recorded on directory
      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      assert updated_directory.error_message != nil
      # The error message contains the user object that caused the failure
      assert updated_directory.error_message =~ "user_123"
      assert updated_directory.errored_at != nil
    end

    test "ErrorHandler classifies 403 as client_error and disables directory" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock successful token, 403 on apps
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{
              "errorCode" => "E0000006",
              "errorSummary" => "Access denied"
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Capture the raised exception
      exception =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      # Simulate Oban telemetry error handling
      job = %Oban.Job{
        id: 1,
        args: %{"directory_id" => directory.id},
        worker: "Portal.Okta.Sync",
        queue: "okta_sync",
        meta: %{}
      }

      meta = %{reason: exception, job: job}
      Portal.DirectorySync.ErrorHandler.handle_error(meta)

      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Access denied"
    end
  end

  describe "circuit breaker protection" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "raises SyncError when identity deletion is 100%" do
      account = account_fixture(features: %{idp_sync: true})

      # Create directory that has already been synced (not a first sync)
      past_sync_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: past_sync_time
        )

      # Get the base directory for associations
      base_directory =
        Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      # Create 5 existing identities
      # All with last_synced_at in the past, so they would all be deleted
      for i <- 1..5 do
        actor =
          Portal.ActorFixtures.actor_fixture(
            account: account,
            type: :account_user,
            email: "user#{i}@example.com"
          )

        Portal.IdentityFixtures.identity_fixture(
          account: account,
          actor: actor,
          directory: base_directory,
          idp_id: "okta_user_#{i}",
          issuer: "https://#{directory.okta_domain}",
          email: "user#{i}@example.com",
          last_synced_at: past_sync_time
        )
      end

      # Mock API to return zero users (simulating Okta app removal)
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            # Return empty list - all users would be deleted
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError due to circuit breaker
      assert_raise SyncError, ~r/would delete all identities/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end

      # Verify no identities were deleted
      identity_count =
        from(i in Portal.ExternalIdentity,
          where: i.directory_id == ^directory.id,
          select: count(i.id)
        )
        |> Repo.one!()

      assert identity_count == 5
    end

    test "raises SyncError when group deletion is 100%" do
      account = account_fixture(features: %{idp_sync: true})

      past_sync_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: past_sync_time
        )

      base_directory =
        Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      # Create 12 existing groups
      for i <- 1..5 do
        Portal.GroupFixtures.group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "okta_group_#{i}",
          last_synced_at: past_sync_time
        )
      end

      # Also create some identities that will sync successfully
      # (so identity check passes, but group check fails)
      for i <- 1..5 do
        actor =
          Portal.ActorFixtures.actor_fixture(
            account: account,
            type: :account_user,
            email: "user#{i}@example.com"
          )

        Portal.IdentityFixtures.identity_fixture(
          account: account,
          actor: actor,
          directory: base_directory,
          idp_id: "okta_user_#{i}",
          issuer: "https://#{directory.okta_domain}",
          email: "user#{i}@example.com",
          last_synced_at: past_sync_time
        )
      end

      # Mock API to return users but no groups
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            # Return the same users to keep them synced
            Req.Test.json(
              conn,
              for i <- 1..5 do
                %{
                  "id" => "appuser_#{i}",
                  "_embedded" => %{
                    "user" => %{
                      "id" => "okta_user_#{i}",
                      "profile" => %{
                        "email" => "user#{i}@example.com",
                        "firstName" => "User",
                        "lastName" => "#{i}"
                      }
                    }
                  }
                }
              end
            )

          String.contains?(path, "/apps/app_123/groups") ->
            # Return empty list - all groups would be deleted
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError due to circuit breaker on groups
      assert_raise SyncError, ~r/would delete all groups/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end

      # Verify no groups were deleted
      group_count =
        from(g in Portal.Group,
          where: g.directory_id == ^directory.id,
          select: count(g.id)
        )
        |> Repo.one!()

      assert group_count == 5
    end

    test "allows deletion below threshold" do
      account = account_fixture(features: %{idp_sync: true})

      past_sync_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: past_sync_time
        )

      base_directory =
        Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      # Create 10 identities - 8 will be synced, 2 will be deleted (20%)
      for i <- 1..10 do
        actor =
          Portal.ActorFixtures.actor_fixture(
            account: account,
            type: :account_user,
            email: "user#{i}@example.com"
          )

        Portal.IdentityFixtures.identity_fixture(
          account: account,
          actor: actor,
          directory: base_directory,
          idp_id: "okta_user_#{i}",
          issuer: "https://#{directory.okta_domain}",
          email: "user#{i}@example.com",
          last_synced_at: past_sync_time
        )
      end

      # Mock API to return 8 of 10 users (20% deletion)
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            # Return 8 of 10 users
            Req.Test.json(
              conn,
              for i <- 1..8 do
                %{
                  "id" => "appuser_#{i}",
                  "_embedded" => %{
                    "user" => %{
                      "id" => "okta_user_#{i}",
                      "profile" => %{
                        "email" => "user#{i}@example.com",
                        "firstName" => "User",
                        "lastName" => "#{i}"
                      }
                    }
                  }
                }
              end
            )

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should succeed - deletion is below threshold
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify 2 identities were deleted
      identity_count =
        from(i in Portal.ExternalIdentity,
          where: i.directory_id == ^directory.id,
          select: count(i.id)
        )
        |> Repo.one!()

      assert identity_count == 8
    end

    test "skips threshold check on first sync" do
      account = account_fixture(features: %{idp_sync: true})

      # Create directory with synced_at = nil (first sync)
      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: nil
        )

      # Mock API to return empty results
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should succeed even though nothing is returned (first sync)
      assert :ok = perform_job(Sync, %{directory_id: directory.id})
    end
  end
end
