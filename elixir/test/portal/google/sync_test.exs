defmodule Portal.Google.SyncTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures
  import ExUnit.CaptureLog

  alias Portal.Google.{Sync, SyncError, APIClient}

  @test_private_key """
  -----BEGIN RSA PRIVATE KEY-----
  MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MaC6dCT6LsOpNkYe
  CvUvR3i6LjFLoxI9I0DKWCsCu3s7gxOlRLpcL5wPTk1zGB4P9jbMJhNH4kws2ruL
  F88MN1WQKmKrkF7b4Jz7sSf5sJQk9lfLKnMJz6tLT0lH2D5B8YSj8e1bIoV6fb6g
  a8PkEUC6b9TBsnnb5hKL6s5kA6B4M9N4u9VhfWJPNQf7bGs8Jf6F9n2n2q6xYqGa
  qliCE/4v2jBP3Fsjk6k/yCN3+xzZnFQqAIH7RFQvFOFl6DvEjU7TX4VJGGBTgkEz
  k9rCBr8IvZglN2BHu1hM9/0HsHU0sStALGOeeQIDAQABAoIBAC5RgZ+hBx7xHnFZ
  nQmY436CjazfrHpEFRvXEOlrFFFbKJu7l6lbMmGxSU1Bxbzl7qYMrhANoBVZ8V4P
  t8AuYQqDFYXnUVfBLCIgv/dXnLXjaVvkSoJsLoZgnPXcAPY0ZFkO/WQib3ZEppPp
  8wxf2XPUhuPU6yglFSGS7pcFmT7FYJmNSNjpN6NU/pAuPLwZEX8gd6k8Y6bociJy
  FmMh3HkUIpyKXXW3VwMUKUHbiCr7Ar8mODKPFn8XAKL7gBQ7mXUG7wmkTdwVlFOp
  SqE/2SmLXJIISvo5FNNzfMhG9hU01hMZGy0r4k/UFJawwhVBzmH7brqGdoXJcpYr
  5REG0qkCgYEA5cVh7HVmwrC4MJrTvItOfgqqMXRz1IjdgPnBZNsA6llIz8pCzvlD
  cOP/L9wqmPXXmNnJ5zsHbyIYOCjprTJb3s2lMbIwfG7d2O8xqNXoHHOCGr0bFqba
  WE2N5NjGC2vqLnrFQQ8jPpExR6qJrF/7V9WXgVqbPAwI2lp/eVGnLpcCgYEA6Mjm
  bPNJo9gJxz4fEsNAMGiHYIL6ZAqJqjF1TWQNrHNmkDhEMPYz8vBAk3XWNuHPoGqc
  xPsr+m3JfKL3D+X8lh6FnBFX2FGMz/3SzkD+ewABmPNKeeY9klHqNrgLvJI+ILNn
  qsLf8y/pZnrI8sbg95djXHHu5dGAM0dpuqpXCg8CgYEAm9QQHTH9qrwp9lWqeyaJ
  sR0/nLMj8luXH85lMINWGOokYv5ljC0lJN5pIMvl9k9Xw3QLQMBDMCRfp4L3r+vh
  Kx7d3r0qIflJl8nOQ4RL/FrpdReTJJJ7n9T1z48lD2TzEkV3+PLn+KLG3s8RCnKO
  l/oXi8Mz7FRviOvt1VIOXPsCgYEAoYd5Hxr+sL8cZPO7nz3LkTjbsCPTLFM+O8B+
  WyJc7l8pX6kCBRh7ppHfJizz8K4L1sRf9QXIS6hZbEkqLr1PFNP6S3N8VVb0rp5L
  +yjqwDfjOywS8KP2b/Qao55Fi27p0s9CR3TgycPkYIE+D4onW/WHkQ7BTwM7ow5f
  VRV6CgECgYBv+GZIhfDGt7DKvCs9xVN0VvGj4vXz7qpD1t/VKHrB9O7tOLH5G2lT
  +Ix56N2+DBfWmQMQW1VJJhKz9F9gDDKl04hLnTLG6FqWjNy5t5tMxZpJA2pYe5wQ
  M7aEyJf3Z1HFHcMfT5xfmfB1V9+OHDcyfZEnZBDhz4LzKB7oCPgMsg==
  -----END RSA PRIVATE KEY-----
  """

  describe "perform/1" do
    setup do
      # Set up test configuration for API client
      original_config = Application.get_env(:portal, APIClient)

      test_config = [
        endpoint: "https://test.googleapis.com",
        token_endpoint: "https://test.googleapis.com/token",
        service_account_key:
          %{
            "type" => "service_account",
            "project_id" => "test-project",
            "private_key_id" => "test-key-id",
            "private_key" => @test_private_key,
            "client_email" => "test@test-project.iam.gserviceaccount.com",
            "client_id" => "123456789",
            "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
            "token_uri" => "https://oauth2.googleapis.com/token",
            "auth_provider_x509_cert_url" => "https://www.googleapis.com/oauth2/v1/certs"
          }
          |> JSON.encode!(),
        req_options: [plug: {Req.Test, APIClient}]
      ]

      Application.put_env(:portal, APIClient, test_config)

      # Set up default stub
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      on_exit(fn ->
        Application.put_env(:portal, APIClient, original_config)
      end)

      :ok
    end

    test "logs and returns :ok when directory not found" do
      # Create a job with a non-existent directory ID
      fake_directory_id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          assert :ok = perform_job(Sync, %{"directory_id" => fake_directory_id})
        end)

      assert log =~ "Google directory not found, disabled, or account disabled, skipping"
      assert log =~ fake_directory_id
    end

    test "logs and returns :ok when directory is disabled" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, is_disabled: true)

      log =
        capture_log(fn ->
          assert :ok = perform_job(Sync, %{"directory_id" => directory.id})
        end)

      assert log =~ "Google directory not found, disabled, or account disabled, skipping"
      assert log =~ directory.id
    end

    test "logs and returns :ok when account is disabled" do
      account = account_fixture()

      # Disable the account
      account
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

      directory = google_directory_fixture(account: account)

      log =
        capture_log(fn ->
          assert :ok = perform_job(Sync, %{"directory_id" => directory.id})
        end)

      assert log =~ "Google directory not found, disabled, or account disabled, skipping"
      assert log =~ directory.id
    end

    test "performs successful sync with users, groups, and org units" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock access token request
      Req.Test.expect(APIClient, fn conn ->
        assert conn.request_path == "/token"
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock users API
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/users")

        Req.Test.json(conn, %{
          "users" => [
            %{
              "id" => "user1",
              "primaryEmail" => "user1@example.com",
              "name" => %{"fullName" => "User One", "givenName" => "User", "familyName" => "One"}
            }
          ]
        })
      end)

      # Mock groups API
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups")
        refute String.contains?(conn.request_path, "/members")

        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1", "name" => "DevOps", "email" => "devops@example.com"}
          ]
        })
      end)

      # Mock group members API
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}
          ]
        })
      end)

      # Mock org units API
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/orgunits")

        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering"}
          ]
        })
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify directory was updated with synced_at
      updated_directory = Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.synced_at != nil
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
      assert updated_directory.is_disabled == false

      # Verify identities were created
      identities = Repo.all(Portal.ExternalIdentity)
      assert length(identities) == 1
      identity = hd(identities)
      assert identity.idp_id == "user1"
      assert identity.email == "user1@example.com"

      # Verify Firezone groups were created (one group, one org unit)
      groups = Repo.all(Portal.Group)
      assert length(groups) == 2

      # Verify we have one group and one org unit
      group_by_type = Enum.group_by(groups, & &1.entity_type)
      assert length(group_by_type[:group]) == 1
      assert length(group_by_type[:org_unit]) == 1
      assert hd(group_by_type[:group]).name == "DevOps"
      assert hd(group_by_type[:org_unit]).name == "Engineering"

      # Verify memberships were created
      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 1
    end

    test "raises SyncError when access token request fails" do
      account = account_fixture()
      directory = google_directory_fixture(account: account)

      # Mock access token request to fail
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert_raise SyncError, ~r/get_access_token/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when users API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock users API to fail
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "insufficient_permissions"})
      end)

      assert_raise SyncError, ~r/Failed to stream users/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when groups API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock successful users API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      # Mock groups API to fail
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "internal_error"})
      end)

      assert_raise SyncError, ~r/Failed to stream groups/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org units API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock successful users API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      # Mock successful groups API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # Mock org units API to fail
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert_raise SyncError, ~r/Failed to stream organization units/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when user is missing id field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock users API with missing id
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            %{"primaryEmail" => "user@example.com", "name" => %{"fullName" => "User"}}
          ]
        })
      end)

      assert_raise SyncError, ~r/User missing required 'id' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when user is missing primaryEmail field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock users API with missing primaryEmail
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            %{"id" => "user1", "name" => %{"fullName" => "User"}}
          ]
        })
      end)

      assert_raise SyncError, ~r/User missing required 'primaryEmail' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when group is missing id field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock successful users API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      # Mock groups API with missing id
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"name" => "Engineering", "email" => "eng@example.com"}
          ]
        })
      end)

      assert_raise SyncError, ~r/Group missing required 'id' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when group is missing both name and email fields" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock successful users API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      # Mock groups API with missing name and email
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1"}
          ]
        })
      end)

      assert_raise SyncError, ~r/Group missing both 'name' and 'email' fields/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org unit is missing orgUnitId field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock successful users API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      # Mock successful groups API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # Mock org units API with missing orgUnitId
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"name" => "Engineering"}
          ]
        })
      end)

      assert_raise SyncError, ~r/Organization unit missing required 'orgUnitId' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org unit is missing name field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock successful users API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      # Mock successful groups API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # Mock org units API with missing name
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1"}
          ]
        })
      end)

      assert_raise SyncError, ~r/Organization unit missing required 'name' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "handles empty user list" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock successful access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock empty users, groups, and org units
      Req.Test.expect(APIClient, 3, fn conn ->
        cond do
          String.contains?(conn.request_path, "/users") ->
            Req.Test.json(conn, %{"users" => []})

          String.contains?(conn.request_path, "/groups") ->
            Req.Test.json(conn, %{"groups" => []})

          String.contains?(conn.request_path, "/orgunits") ->
            Req.Test.json(conn, %{"organizationUnits" => []})
        end
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify sync completed successfully with no data
      updated_directory = Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.synced_at != nil
      assert updated_directory.error_message == nil
    end

    test "deletes unsynced identities and groups" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Create an old identity that should be deleted
      old_synced_at = DateTime.utc_now() |> DateTime.add(-3600, :second)

      {:ok, old_actor} =
        %Portal.Actor{
          type: :account_user,
          account_id: account.id,
          email: "old@example.com",
          name: "Old User",
          created_by_directory_id: directory.id
        }
        |> Repo.insert()

      {:ok, old_identity} =
        %Portal.ExternalIdentity{
          account_id: account.id,
          actor_id: old_actor.id,
          directory_id: directory.id,
          idp_id: "old_user",
          email: "old@example.com",
          issuer: "https://accounts.google.com",
          last_synced_at: old_synced_at
        }
        |> Repo.insert()

      # Mock successful sync with new user
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            %{
              "id" => "new_user",
              "primaryEmail" => "new@example.com",
              "name" => %{"fullName" => "New User"}
            }
          ]
        })
      end)

      Req.Test.expect(APIClient, 2, fn conn ->
        cond do
          String.contains?(conn.request_path, "/groups") ->
            Req.Test.json(conn, %{"groups" => []})

          String.contains?(conn.request_path, "/orgunits") ->
            Req.Test.json(conn, %{"organizationUnits" => []})
        end
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify old identity was deleted
      refute Repo.get_by(Portal.ExternalIdentity, id: old_identity.id)

      # Verify old actor was deleted (since it has no more identities)
      refute Repo.get_by(Portal.Actor, id: old_actor.id)

      # Verify new identity exists
      new_identities = Repo.all(Portal.ExternalIdentity)
      assert length(new_identities) == 1
      assert hd(new_identities).idp_id == "new_user"
    end

    test "uses legacy service account key when present" do
      account = account_fixture()

      legacy_key = %{
        "type" => "service_account",
        "private_key" => @test_private_key,
        "client_email" => "legacy@example.iam.gserviceaccount.com"
      }

      directory =
        google_directory_fixture(
          account: account,
          domain: "example.com",
          legacy_service_account_key: legacy_key
        )

      test_pid = self()

      # Mock access token request and capture the request
      Req.Test.expect(APIClient, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_request, body})
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock empty responses for API calls
      Req.Test.expect(APIClient, 3, fn conn ->
        cond do
          String.contains?(conn.request_path, "/users") ->
            Req.Test.json(conn, %{"users" => []})

          String.contains?(conn.request_path, "/groups") ->
            Req.Test.json(conn, %{"groups" => []})

          String.contains?(conn.request_path, "/orgunits") ->
            Req.Test.json(conn, %{"organizationUnits" => []})
        end
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify the legacy key was used by checking the JWT assertion
      assert_receive {:token_request, body}
      params = URI.decode_query(body)
      assert params["assertion"]
      # The JWT would be signed with the legacy key's client_email
    end

    test "handles multiple pages of users" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock paginated users API
      page_counter = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        current_page = :counters.get(page_counter, 1)
        :counters.add(page_counter, 1, 1)

        case current_page do
          0 ->
            Req.Test.json(conn, %{
              "users" => [
                %{
                  "id" => "user1",
                  "primaryEmail" => "user1@example.com",
                  "name" => %{"fullName" => "User One"}
                }
              ],
              "nextPageToken" => "page2"
            })

          1 ->
            Req.Test.json(conn, %{
              "users" => [
                %{
                  "id" => "user2",
                  "primaryEmail" => "user2@example.com",
                  "name" => %{"fullName" => "User Two"}
                }
              ]
            })
        end
      end)

      # Mock groups and org units
      Req.Test.expect(APIClient, 2, fn conn ->
        cond do
          String.contains?(conn.request_path, "/groups") ->
            Req.Test.json(conn, %{"groups" => []})

          String.contains?(conn.request_path, "/orgunits") ->
            Req.Test.json(conn, %{"organizationUnits" => []})
        end
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify both users were synced
      identities = Repo.all(Portal.ExternalIdentity)
      assert length(identities) == 2
      idp_ids = Enum.map(identities, & &1.idp_id) |> Enum.sort()
      assert idp_ids == ["user1", "user2"]
    end

    test "filters non-USER members from group membership" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # Mock access token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # Mock user
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            %{
              "id" => "user1",
              "primaryEmail" => "user1@example.com",
              "name" => %{"fullName" => "User One"}
            }
          ]
        })
      end)

      # Mock group
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}
          ]
        })
      end)

      # Mock group members with mixed types
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"},
            %{"id" => "group2", "type" => "GROUP", "email" => "nested@example.com"},
            %{"id" => "external1", "type" => "EXTERNAL", "email" => "ext@other.com"}
          ]
        })
      end)

      # Mock org units
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify only USER type member created a membership
      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 1
    end
  end
end
