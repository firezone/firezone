defmodule Portal.Google.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.ResourceFixtures
  import ExUnit.CaptureLog

  alias Portal.Google.{Sync, SyncError, APIClient}
  alias Portal.Google.Sync.Database

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

  # Builds a valid multipart/mixed batch response and sends it via the conn.
  # `users` is a list of user maps to include as 200 OK parts.
  defp respond_with_batch_users(conn, users) do
    boundary = "test_batch_response_boundary"

    parts =
      Enum.map(users, fn user ->
        json = JSON.encode!(user)

        "--#{boundary}\r\nContent-Type: application/http\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n#{json}\r\n"
      end)

    body = Enum.join(parts, "") <> "--#{boundary}--"

    conn
    |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
    |> Plug.Conn.send_resp(200, body)
  end

  describe "perform/1" do
    setup do
      # Set up test configuration for API client. Use a process-scoped override
      # (via Portal.Config.put_env_override) instead of Application.put_env so
      # that concurrent async tests don't clobber each other's global config.
      original_log_level = Logger.level()

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
        req_opts: [plug: {Req.Test, APIClient}, retry: false]
      ]

      Portal.Config.put_env_override(:portal, APIClient, test_config)
      Logger.configure(level: :debug)

      # Set up default stub
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      on_exit(fn ->
        Logger.configure(level: original_log_level)
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

    test "performs successful sync with groups, org units, and user identity sync" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        assert conn.request_path == "/token"
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups")
        refute String.contains?(conn.request_path, "/members")

        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1", "name" => "DevOps", "email" => "devops@example.com"}
          ]
        })
      end)

      # 3. Org units API
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/orgunits")

        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering", "orgUnitPath" => "/Engineering"}
          ]
        })
      end)

      # 4. Org unit members for /Engineering (now synced before group BFS)
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/users")
        assert String.contains?(conn.query_string || "", "orgUnitPath")

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

      # 5. Group members for group1 (BFS phase)
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}
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

      # Verify identity was created
      identities = Repo.all(Portal.ExternalIdentity)
      assert length(identities) == 1
      identity = hd(identities)
      assert identity.idp_id == "user1"
      assert identity.email == "user1@example.com"

      # Verify Firezone groups were created (one group, one org unit)
      groups = Repo.all(Portal.Group)
      assert length(groups) == 2

      group_by_type = Enum.group_by(groups, & &1.entity_type)
      assert length(group_by_type[:group]) == 1
      assert length(group_by_type[:org_unit]) == 1
      assert hd(group_by_type[:group]).name == "DevOps"
      assert hd(group_by_type[:group]).email == "devops@example.com"
      assert hd(group_by_type[:org_unit]).name == "Engineering"

      # Verify memberships were created (one for group, one for org unit)
      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 2
    end

    test "skips group members without a binary email" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "DevOps", "email" => "devops@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "bad_user", "type" => "USER", "email" => nil},
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}
          ]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        respond_with_batch_users(conn, [%{"id" => "user1", "primaryEmail" => "user1@example.com"}])
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      identities = Repo.all(Portal.ExternalIdentity)
      assert Enum.map(identities, & &1.idp_id) == ["user1"]
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

    test "raises SyncError when groups API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API fails
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "internal_error"})
      end)

      assert_raise SyncError, ~r/at stream_groups: HTTP 500/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org units API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API succeeds (empty)
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units API fails
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert_raise SyncError, ~r/at stream_org_units: HTTP 403/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when group member is missing id field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API returns group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      # 3. Org units
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. Group members — member is missing "id" field
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"type" => "USER", "email" => "user@example.com"}
          ]
        })
      end)

      assert_raise SyncError, ~r/member missing 'id' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when get_user returns user missing primaryEmail field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API returns group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      # 3. Org units
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. Group members returns user1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [%{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}]
        })
      end)

      # 5. batch_get_users returns user without primaryEmail
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{"id" => "user1", "name" => %{"fullName" => "User"}}
        ])
      end)

      assert_raise SyncError, ~r/user .* missing 'primaryEmail' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when group is missing id field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API returns group without id
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"name" => "Engineering", "email" => "eng@example.com"}
          ]
        })
      end)

      assert_raise SyncError, ~r/group missing 'id' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when group is missing both name and email fields" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API returns group with only id
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1"}
          ]
        })
      end)

      assert_raise SyncError, ~r/group .* missing 'name' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org unit is missing orgUnitId field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units API with missing orgUnitId
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"name" => "Engineering"}
          ]
        })
      end)

      assert_raise SyncError, ~r/org_unit missing 'orgUnitId' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org unit is missing name field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units API with missing name
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1"}
          ]
        })
      end)

      assert_raise SyncError, ~r/org_unit .* missing 'name' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org unit is missing orgUnitPath field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups API
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units API with missing orgUnitPath
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering"}
          ]
        })
      end)

      assert_raise SyncError, ~r/org_unit .* missing 'orgUnitPath' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "handles empty groups and org units" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups")
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/orgunits")
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # No group members, no org unit members, no get_user calls

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

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

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1 with new_user as member
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. Group members → new_user
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [%{"id" => "new_user", "type" => "USER", "email" => "new@example.com"}]
        })
      end)

      # 5. batch_get_users for new_user
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "new_user",
            "primaryEmail" => "new@example.com",
            "name" => %{"fullName" => "New User"}
          }
        ])
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
          legacy_service_account_key: nil
        )

      Repo.update!(Ecto.Changeset.change(directory, legacy_service_account_key: legacy_key))

      test_pid = self()

      # 1. Token — capture the request to verify legacy key was used
      Req.Test.expect(APIClient, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_request, body})
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups")
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/orgunits")
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify the legacy key was used by checking the JWT assertion
      assert_receive {:token_request, body}
      params = URI.decode_query(body)
      assert params["assertion"]
    end

    test "handles multiple pages of group members" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. Group members — paginated: page 1 returns user1 with nextPageToken
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")
        refute String.contains?(conn.query_string || "", "pageToken")

        Req.Test.json(conn, %{
          "members" => [%{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}],
          "nextPageToken" => "page2"
        })
      end)

      # 5. Group members — page 2 returns user2
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")
        assert String.contains?(conn.query_string || "", "pageToken")

        Req.Test.json(conn, %{
          "members" => [%{"id" => "user2", "type" => "USER", "email" => "user2@example.com"}]
        })
      end)

      # 6. batch_get_users for user1 and user2 (both in a single batch call, accumulated from both pages)
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "user1",
            "primaryEmail" => "user1@example.com",
            "name" => %{"fullName" => "User One"}
          },
          %{
            "id" => "user2",
            "primaryEmail" => "user2@example.com",
            "name" => %{"fullName" => "User Two"}
          }
        ])
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify both users were synced
      identities = Repo.all(Portal.ExternalIdentity)
      assert length(identities) == 2
      idp_ids = Enum.map(identities, & &1.idp_id) |> Enum.sort()
      assert idp_ids == ["user1", "user2"]
    end

    test "discovers GROUP-type members as sub-groups and only creates USER-type memberships for the parent" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}
          ]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. Group members for group1: USER user1, GROUP group2, EXTERNAL ext1
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"},
            %{"id" => "group2", "type" => "GROUP", "email" => "nested@example.com"},
            %{"id" => "external1", "type" => "EXTERNAL", "email" => "ext@other.com"}
          ]
        })
      end)

      # 5. batch_get_users for user1 only (GROUP and EXTERNAL do not become USER identities)
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "user1",
            "primaryEmail" => "user1@example.com",
            "name" => %{"fullName" => "User One"}
          }
        ])
      end)

      # 6. get_group("group2") — BFS fetches full details for the discovered sub-group
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2")
        refute String.contains?(conn.request_path, "/members")

        Req.Test.json(conn, %{
          "id" => "group2",
          "name" => "Nested Team",
          "email" => "nested@example.com"
        })
      end)

      # 7. Group members for group2 (BFS continues into the discovered sub-group) → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2/members")
        Req.Test.json(conn, %{"members" => []})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify group1 (seed) and group2 (discovered via BFS) both exist as portal groups
      groups = Repo.all(Portal.Group) |> Enum.sort_by(& &1.idp_id)
      assert length(groups) == 2

      [g1, g2] = groups
      assert g1.idp_id == "group1"
      assert g1.name == "Engineering"
      assert g1.email == "eng@example.com"
      assert g2.idp_id == "group2"
      assert g2.name == "Nested Team"
      assert g2.email == "nested@example.com"

      # Only user1 (USER type) created a membership in group1; group2 has no members
      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 1
    end

    test "skips type=USER members whose email belongs to a different domain" do
      # Regression: Google groups can contain external users (from other Google Workspace
      # domains or personal Gmail accounts) that the Admin SDK returns with type="USER"
      # (the documented EXTERNAL type is marked "not currently used"). Calling users.get
      # for these IDs returns 403 Forbidden because the service account's domain-wide
      # delegation only covers the customer's own domain. We must filter them out
      # before passing IDs to batch_get_users.
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}
          ]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. Group members: internal user1, external user appearing as type=USER with
      #    a foreign domain email (this is what Google actually returns in production),
      #    and an external user with the documented-but-unused EXTERNAL type.
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"},
            %{"id" => "extuser", "type" => "USER", "email" => "extuser@otherdomain.com"},
            %{"id" => "extuser2", "type" => "EXTERNAL", "email" => "extuser2@otherdomain.com"}
          ]
        })
      end)

      # 5. batch_get_users — must only contain user1; extuser must NOT be included
      #    (if it were, Google would return 403, failing the entire sync)
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "user1")
        refute String.contains?(body, "extuser")

        respond_with_batch_users(conn, [
          %{
            "id" => "user1",
            "primaryEmail" => "user1@example.com",
            "name" => %{"fullName" => "User One"}
          }
        ])
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Only the internal domain user has an identity
      identities = Repo.all(Portal.ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).idp_id == "user1"

      # Only user1 has a membership
      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 1
    end

    test "syncs transitive sub-groups recursively and creates memberships at each level" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # group1 (seed) → [GROUP group2] → [USER user2, GROUP group3] → [USER user3]

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1 only (seed)
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Top Level", "email" => "top@example.com"}]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. group1 members: GROUP group2 (no direct USER members)
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [%{"id" => "group2", "type" => "GROUP", "email" => "mid@example.com"}]
        })
      end)

      # 5. get_group("group2")
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2")
        refute String.contains?(conn.request_path, "/members")

        Req.Test.json(conn, %{
          "id" => "group2",
          "name" => "Middle Level",
          "email" => "mid@example.com"
        })
      end)

      # 6. group2 members: USER user2 + GROUP group3
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user2", "type" => "USER", "email" => "user2@example.com"},
            %{"id" => "group3", "type" => "GROUP", "email" => "leaf@example.com"}
          ]
        })
      end)

      # 7. batch_get_users for user2 (new)
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "user2",
            "primaryEmail" => "user2@example.com",
            "name" => %{"fullName" => "User Two"}
          }
        ])
      end)

      # 8. get_group("group3")
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group3")
        refute String.contains?(conn.request_path, "/members")

        Req.Test.json(conn, %{
          "id" => "group3",
          "name" => "Leaf Level",
          "email" => "leaf@example.com"
        })
      end)

      # 9. group3 members: USER user3
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group3/members")

        Req.Test.json(conn, %{
          "members" => [%{"id" => "user3", "type" => "USER", "email" => "user3@example.com"}]
        })
      end)

      # 10. batch_get_users for user3 (new)
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "user3",
            "primaryEmail" => "user3@example.com",
            "name" => %{"fullName" => "User Three"}
          }
        ])
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # All three portal groups were created
      groups = Repo.all(Portal.Group) |> Enum.sort_by(& &1.idp_id)
      assert Enum.map(groups, & &1.idp_id) == ["group1", "group2", "group3"]
      assert Enum.map(groups, & &1.name) == ["Top Level", "Middle Level", "Leaf Level"]

      # Flattened memberships:
      # group1 -> user2,user3 ; group2 -> user2,user3 ; group3 -> user3
      memberships =
        Repo.all(Portal.Membership)
        |> Repo.preload([:group, :actor])
        |> Enum.map(fn m -> {m.group.idp_id, m.actor.name} end)
        |> Enum.sort()

      assert memberships == [
               {"group1", "User Three"},
               {"group1", "User Two"},
               {"group2", "User Three"},
               {"group2", "User Two"},
               {"group3", "User Three"}
             ]

      identities = Repo.all(Portal.ExternalIdentity) |> Enum.sort_by(& &1.idp_id)
      assert Enum.map(identities, & &1.idp_id) == ["user2", "user3"]
    end

    test "BFS stops when a sub-group has already been visited (cycle prevention)" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # group1 (seed) → [GROUP group2]
      # group2 → [USER user1, GROUP group1]  ← group1 already visited, stops here

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Group One", "email" => "g1@example.com"}]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. group1 members → GROUP group2 (no USER members)
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [%{"id" => "group2", "type" => "GROUP", "email" => "g2@example.com"}]
        })
      end)

      # 5. get_group("group2")
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2")
        refute String.contains?(conn.request_path, "/members")

        Req.Test.json(conn, %{
          "id" => "group2",
          "name" => "Group Two",
          "email" => "g2@example.com"
        })
      end)

      # 6. group2 members → USER user1 + GROUP group1 (cycle back to already-visited group1)
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"},
            %{"id" => "group1", "type" => "GROUP", "email" => "g1@example.com"}
          ]
        })
      end)

      # 7. batch_get_users for user1
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "user1",
            "primaryEmail" => "user1@example.com",
            "name" => %{"fullName" => "User One"}
          }
        ])
      end)

      # No get_group("group1") call — it's already in visited, BFS skips it

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      groups = Repo.all(Portal.Group) |> Enum.sort_by(& &1.idp_id)
      assert Enum.map(groups, & &1.idp_id) == ["group1", "group2"]

      memberships =
        Repo.all(Portal.Membership)
        |> Repo.preload([:group, :actor])
        |> Enum.map(fn m -> {m.group.idp_id, m.actor.name} end)
        |> Enum.sort()

      assert memberships == [
               {"group1", "User One"},
               {"group2", "User One"}
             ]
    end

    test "BFS skips sub-groups that no longer exist in Google (404)" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Top", "email" => "top@example.com"}]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. group1 members → GROUP deleted_group
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "deleted_group", "type" => "GROUP", "email" => "gone@example.com"}
          ]
        })
      end)

      # 5. get_group("deleted_group") → 404
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/deleted_group")

        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "Resource Not Found"}})
      end)

      # No group2 members call — it was skipped

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Only group1 exists; deleted_group was silently skipped
      groups = Repo.all(Portal.Group)
      assert length(groups) == 1
      assert hd(groups).idp_id == "group1"
    end

    test "BFS skips sub-groups that are inaccessible (403, e.g. external domain groups)" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → group1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Top", "email" => "top@example.com"}]
        })
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 4. group1 members → GROUP from external domain
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "external_group", "type" => "GROUP", "email" => "team@otherdomain.com"}
          ]
        })
      end)

      # 5. get_group("external_group") → 403
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/external_group")

        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "error" => %{"code" => 403, "message" => "Not Authorized to access this resource/api"}
        })
      end)

      # No members call for external_group — it was skipped

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Only group1 exists; external_group was silently skipped
      groups = Repo.all(Portal.Group)
      assert length(groups) == 1
      assert hd(groups).idp_id == "group1"
    end

    test "group_sync_mode :filtered issues separate email and name prefix queries, then syncs members" do
      account = account_fixture()

      directory =
        google_directory_fixture(
          account: account,
          domain: "example.com",
          group_sync_mode: :filtered
        )

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. First groups call: email prefix query → group1
      Req.Test.expect(APIClient, fn conn ->
        refute String.contains?(conn.request_path, "/members")
        assert String.contains?(conn.query_string, "email%3Afirezone-sync")

        Req.Test.json(conn, %{
          "groups" => [
            %{
              "id" => "group1",
              "name" => "firezone-sync-admins",
              "email" => "firezone-sync-admins@example.com"
            }
          ]
        })
      end)

      # 3. Second groups call: name prefix query → group2
      Req.Test.expect(APIClient, fn conn ->
        refute String.contains?(conn.request_path, "/members")
        assert String.contains?(conn.query_string, "name%3A%5Bfirezone-sync%5D")

        Req.Test.json(conn, %{
          "groups" => [
            %{"id" => "group2", "name" => "[firezone-sync] ops", "email" => "ops@example.com"}
          ]
        })
      end)

      # 4. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      # 5. Group members for group1 → user1
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group1/members")

        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}
          ]
        })
      end)

      # 6. batch_get_users for user1 (right after group1 members in BFS)
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        respond_with_batch_users(conn, [
          %{
            "id" => "user1",
            "primaryEmail" => "user1@example.com",
            "name" => %{"fullName" => "User One"}
          }
        ])
      end)

      # 7. Group members for group2 → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/groups/group2/members")
        Req.Test.json(conn, %{"members" => []})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      groups = Repo.all(Portal.Group) |> Enum.sort_by(& &1.idp_id)
      assert length(groups) == 2
      assert Enum.map(groups, & &1.idp_id) == ["group1", "group2"]

      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 1
    end

    test "group_sync_mode :disabled skips group sync — stale groups are deleted" do
      account = account_fixture()

      directory =
        google_directory_fixture(
          account: account,
          domain: "example.com",
          group_sync_mode: :disabled
        )

      # Pre-existing group with stale last_synced_at
      old_synced_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, existing_group} =
        %Portal.Group{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          directory_id: directory.id,
          idp_id: "group-devops",
          name: "DevOps",
          type: :static,
          entity_type: :group,
          last_synced_at: old_synced_at
        }
        |> Repo.insert()

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # No groups API call expected (mode is :disabled)

      # 2. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.request_path, "/orgunits")
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Stale group was not synced this run — delete_unsynced removes it
      refute Repo.get_by(Portal.Group, id: existing_group.id)
    end

    test "orgunit_sync_enabled false skips org unit sync — stale org units are deleted" do
      account = account_fixture()

      directory =
        google_directory_fixture(
          account: account,
          domain: "example.com",
          orgunit_sync_enabled: false
        )

      old_synced_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, existing_ou} =
        %Portal.Group{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          directory_id: directory.id,
          idp_id: "ou-engineering",
          name: "Engineering",
          type: :static,
          entity_type: :org_unit,
          last_synced_at: old_synced_at
        }
        |> Repo.insert()

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # No org units API call expected (orgunit_sync_enabled: false)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Stale org unit was not synced this run — delete_unsynced removes it
      refute Repo.get_by(Portal.Group, id: existing_ou.id)
    end

    test "group_sync_mode :disabled and orgunit_sync_enabled false — all stale groups deleted" do
      account = account_fixture()

      directory =
        google_directory_fixture(
          account: account,
          domain: "example.com",
          group_sync_mode: :disabled,
          orgunit_sync_enabled: false
        )

      old_synced_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, existing_group} =
        %Portal.Group{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          directory_id: directory.id,
          idp_id: "group-devops",
          name: "DevOps",
          type: :static,
          entity_type: :group,
          last_synced_at: old_synced_at
        }
        |> Repo.insert()

      {:ok, existing_ou} =
        %Portal.Group{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          directory_id: directory.id,
          idp_id: "ou-engineering",
          name: "Engineering",
          type: :static,
          entity_type: :org_unit,
          last_synced_at: old_synced_at
        }
        |> Repo.insert()

      # 1. Token only — no groups or org units API calls
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Both are stale — delete_unsynced removes them
      refute Repo.get_by(Portal.Group, id: existing_group.id)
      refute Repo.get_by(Portal.Group, id: existing_ou.id)
    end

    test "group_sync_mode :filtered deletes non-matching groups" do
      account = account_fixture()

      directory =
        google_directory_fixture(
          account: account,
          domain: "example.com",
          group_sync_mode: :filtered
        )

      old_synced_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      # A stale group that does NOT match the firezone-sync prefix
      {:ok, non_matching_group} =
        %Portal.Group{
          id: Ecto.UUID.generate(),
          account_id: account.id,
          directory_id: directory.id,
          idp_id: "group-devops",
          name: "DevOps",
          type: :static,
          entity_type: :group,
          last_synced_at: old_synced_at
        }
        |> Repo.insert()

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Both prefix queries return empty (no firezone-sync groups in Google)
      Req.Test.expect(APIClient, 2, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Non-matching group is stale — delete_unsynced removes it
      refute Repo.get_by(Portal.Group, id: non_matching_group.id)
    end

    test "syncs org unit with no members when users key is missing in response" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      # 1. Token
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      # 2. Groups → empty
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      # 3. Org units → ou1
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Empty Dept", "orgUnitPath" => "/EmptyDept"}
          ]
        })
      end)

      # 4. Org unit members — Google omits "users" key for empty org units
      Req.Test.expect(APIClient, fn conn ->
        assert String.contains?(conn.query_string || "", "orgUnitPath")
        Req.Test.json(conn, %{"etag" => "\"p9q284efnuVA987\"", "kind" => "admin#directory#users"})
      end)

      # No get_user calls — no members

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})

      # Verify org unit was created
      groups = Repo.all(Portal.Group)
      assert length(groups) == 1
      org_unit = hd(groups)
      assert org_unit.entity_type == :org_unit
      assert org_unit.name == "Empty Dept"

      # Verify no memberships were created for the empty org unit
      memberships = Repo.all(Portal.Membership)
      assert length(memberships) == 0
    end

    test "raises SyncError when access token transport fails" do
      account = account_fixture()
      directory = google_directory_fixture(account: account)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert_raise SyncError, ~r/get_access_token/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when access token response is missing access_token field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"expires_in" => 3600})
      end)

      assert_raise SyncError, ~r/get_access_token/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when service account key is not configured and no legacy key exists" do
      account = account_fixture()
      directory = google_directory_fixture(account: account)

      config = Process.get({:portal, APIClient})

      Portal.Config.put_env_override(
        :portal,
        APIClient,
        Keyword.put(config, :service_account_key, %{invalid: true})
      )

      assert_raise SyncError, ~r/service account key is not configured/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "logs reconnect count when orphaned policies are reconnected" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")
      resource = resource_fixture(account: account)

      policy =
        Repo.insert!(%Portal.Policy{
          account_id: account.id,
          resource_id: resource.id,
          group_id: nil,
          group_idp_id: "group1",
          description: "Orphaned policy awaiting group reconnection",
          conditions: []
        })

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"members" => []})
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(Sync, %{"directory_id" => directory.id})
        end)

      assert log =~ "Reconnected 1 orphaned policies after sync"
      assert Repo.get_by!(Portal.Policy, id: policy.id, account_id: account.id).group_id != nil
    end

    test "raises SyncError when discovered sub-group is missing both name and email" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Top", "email" => "top@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [%{"id" => "group2", "type" => "GROUP", "email" => "group2@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"id" => "group2"})
      end)

      assert_raise SyncError, ~r/discovered group 'group2' missing 'name' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when discovered sub-group is missing id field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Top", "email" => "top@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [%{"id" => "group2", "type" => "GROUP", "email" => "group2@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"name" => "Nested Group", "email" => "group2@example.com"})
      end)

      assert_raise SyncError, ~r/discovered group missing 'id' field/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when discovered sub-group lookup returns non-404 error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Top", "email" => "top@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [%{"id" => "group2", "type" => "GROUP", "email" => "group2@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server error"})
      end)

      assert_raise SyncError, ~r/get_group/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when group members API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert_raise SyncError, ~r/at stream_group_members: HTTP 403/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when batch_get_users returns error response" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [%{"id" => "user1", "type" => "USER", "email" => "user1@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server error"})
      end)

      assert_raise SyncError, ~r/at batch_get_users: HTTP 500/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "ignores GROUP members with nil id while still syncing valid USER members" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "groups" => [%{"id" => "group1", "name" => "Engineering", "email" => "eng@example.com"}]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"organizationUnits" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "members" => [
            %{"id" => "user1", "type" => "USER", "email" => "user1@example.com"},
            %{"id" => nil, "type" => "GROUP", "email" => "unknown@example.com"}
          ]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        respond_with_batch_users(conn, [
          %{
            "id" => "user1",
            "primaryEmail" => "user1@example.com",
            "name" => %{"fullName" => "User One"}
          }
        ])
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})
      assert Repo.aggregate(Portal.Group, :count, :id) == 1
      assert Repo.aggregate(Portal.Membership, :count, :id) == 1
    end

    test "raises SyncError when org unit members API returns error" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering", "orgUnitPath" => "/Engineering"}
          ]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert_raise SyncError, ~r/at stream_org_unit_members: HTTP 403/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "raises SyncError when org unit user is missing id field" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering", "orgUnitPath" => "/Engineering"}
          ]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => [%{"primaryEmail" => "missing-id@example.com"}]})
      end)

      assert_raise SyncError, ~r/user missing 'id' field in org unit ou1/, fn ->
        perform_job(Sync, %{"directory_id" => directory.id})
      end
    end

    test "syncs identities for new org unit users not seen in group BFS" do
      account = account_fixture()
      directory = google_directory_fixture(account: account, domain: "example.com")

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 3600})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"groups" => []})
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering", "orgUnitPath" => "/Engineering"}
          ]
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            %{
              "id" => "ou_user_1",
              "primaryEmail" => "ou1@example.com",
              "name" => %{"fullName" => "OU User"}
            }
          ]
        })
      end)

      assert :ok = perform_job(Sync, %{"directory_id" => directory.id})
      assert Repo.aggregate(Portal.ExternalIdentity, :count, :id) == 1
      assert Repo.aggregate(Portal.Membership, :count, :id) == 1
    end

    test "Database upsert helpers cover empty and error branches" do
      now = DateTime.utc_now()
      nonexistent_account_id = Ecto.UUID.generate()
      nonexistent_directory_id = Ecto.UUID.generate()

      assert {:ok, %{upserted_identities: 0}} =
               Database.batch_upsert_identities(
                 nonexistent_account_id,
                 nonexistent_directory_id,
                 now,
                 []
               )

      assert {:ok, %{upserted_groups: 0}} =
               Database.batch_upsert_groups(
                 nonexistent_account_id,
                 nonexistent_directory_id,
                 now,
                 [],
                 :group
               )

      assert {:ok, %{upserted_memberships: 0}} =
               Database.batch_upsert_memberships(
                 nonexistent_account_id,
                 nonexistent_directory_id,
                 now,
                 []
               )

      assert {:error, _reason} =
               Database.batch_upsert_groups(
                 nonexistent_account_id,
                 nonexistent_directory_id,
                 now,
                 [%{idp_id: "group1", name: "Group 1", email: "group1@example.com"}],
                 :group
               )

      assert {:error, _reason} =
               Database.batch_upsert_identities(
                 nonexistent_account_id,
                 nonexistent_directory_id,
                 now,
                 [%{idp_id: "user1", email: "u1@example.com", name: "User 1"}]
               )

      assert {:error, _reason} =
               Database.batch_upsert_memberships(
                 nonexistent_account_id,
                 nonexistent_directory_id,
                 "not-a-datetime",
                 [{"group1", "user1"}]
               )
    end

    test "Sync batch upsert wrappers raise and log on database failures" do
      directory = %Portal.Google.Directory{
        id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate()
      }

      identity_log =
        capture_log(fn ->
          assert_raise SyncError, ~r/batch_upsert_identities/, fn ->
            Sync.batch_upsert_identities(directory, DateTime.utc_now(), [
              %{idp_id: "user1", email: "broken@example.com", name: "Broken User"}
            ])
          end
        end)

      assert identity_log =~ "Failed to upsert identities"

      memberships_log =
        capture_log(fn ->
          assert_raise SyncError, ~r/batch_upsert_memberships/, fn ->
            Sync.batch_upsert_memberships(directory, "not-a-datetime", [
              {"group1", "user1"}
            ])
          end
        end)

      assert memberships_log =~ "Failed to upsert memberships"
    end
  end
end
