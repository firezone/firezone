defmodule Portal.Google.APIClientTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Portal.Google.APIClient

  @test_domain "example.com"
  @test_access_token "test_access_token_123"
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

  setup do
    Req.Test.stub(APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    :ok
  end

  describe "get_access_token/2" do
    test "exchanges JWT for access token" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/token"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_request, body, conn})

        Req.Test.json(conn, %{
          "access_token" => "returned_access_token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      end)

      key = %{
        "client_email" => "test@project.iam.gserviceaccount.com",
        "private_key" => @test_private_key
      }

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.get_access_token("admin@example.com", key)

      assert body["access_token"] == "returned_access_token"

      assert_receive {:token_request, request_body, conn}
      assert {"content-type", "application/x-www-form-urlencoded"} in conn.req_headers

      params = URI.decode_query(request_body)
      assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert params["assertion"]
    end

    test "returns error on network failure" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      key = %{
        "client_email" => "test@project.iam.gserviceaccount.com",
        "private_key" => @test_private_key
      }

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               APIClient.get_access_token("admin@example.com", key)
    end
  end

  describe "get_customer/1" do
    test "fetches customer information" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/admin/directory/v1/customers/my_customer"
        send(test_pid, {:customer_request, conn})

        Req.Test.json(conn, %{
          "kind" => "admin#directory#customer",
          "id" => "C12345678",
          "customerDomain" => "example.com"
        })
      end)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.get_customer(@test_access_token)

      assert body["id"] == "C12345678"

      assert_receive {:customer_request, conn}
      assert_authorization_header(conn, @test_access_token)
    end
  end

  describe "get_group/2" do
    test "returns group body for 200 response" do
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/admin/directory/v1/groups/group123"
        Req.Test.json(conn, %{"id" => "group123", "name" => "Engineering"})
      end)

      assert {:ok, %{"id" => "group123", "name" => "Engineering"}} =
               APIClient.get_group(@test_access_token, "group123")
    end

    test "returns :not_found for 404 response" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "not found"})
      end)

      assert {:error, :not_found} = APIClient.get_group(@test_access_token, "missing-group")
    end

    test "returns response error for non-404 non-200 response" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server error"})
      end)

      assert {:error, %Req.Response{status: 500}} =
               APIClient.get_group(@test_access_token, "group123")
    end

    test "returns transport error unchanged" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               APIClient.get_group(@test_access_token, "group123")
    end
  end

  describe "test_connection/2" do
    test "returns :ok when all endpoints are accessible" do
      Req.Test.expect(APIClient, 3, fn conn ->
        Req.Test.json(conn, %{})
      end)

      assert :ok = APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "returns error when users endpoint fails" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      assert {:ok, %Req.Response{status: 403}} =
               APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "returns error when groups endpoint fails" do
      # First call (users) succeeds
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{})
      end)

      # Second call (groups) fails
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      assert {:ok, %Req.Response{status: 403}} =
               APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "returns error when org_units endpoint fails" do
      # First two calls succeed
      Req.Test.expect(APIClient, 2, fn conn ->
        Req.Test.json(conn, %{})
      end)

      # Third call (org_units) fails
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      assert {:ok, %Req.Response{status: 403}} =
               APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "verifies correct query parameters are sent" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:users_query, conn.query_params})
        Req.Test.json(conn, %{})
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:groups_query, conn.query_params})
        Req.Test.json(conn, %{})
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:orgunits_query, conn.query_params})
        Req.Test.json(conn, %{})
      end)

      APIClient.test_connection(@test_access_token, @test_domain)

      assert_receive {:users_query, users_params}
      assert users_params["customer"] == "my_customer"
      assert users_params["domain"] == @test_domain
      assert users_params["maxResults"] == "1"

      assert_receive {:groups_query, groups_params}
      assert groups_params["customer"] == "my_customer"
      assert groups_params["domain"] == @test_domain
      assert groups_params["maxResults"] == "1"

      assert_receive {:orgunits_query, orgunits_params}
      assert orgunits_params["type"] == "all"
    end
  end

  describe "stream_users/2" do
    test "streams a single page of users" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:users_request, conn})

        Req.Test.json(conn, %{
          "kind" => "admin#directory#users",
          "users" => [
            active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"}),
            active_google_user(%{"id" => "user2", "primaryEmail" => "user2@example.com"})
          ]
        })
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}, %{"id" => "user2"}]] = result

      assert_receive {:users_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["customer"] == "my_customer"
      assert conn.query_params["domain"] == @test_domain
      assert conn.query_params["maxResults"] == "500"
      assert conn.query_params["projection"] == "full"
      assert conn.query_params["query"] == "isSuspended=false isArchived=false"
    end

    test "streams multiple pages using nextPageToken" do
      test_pid = self()
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 3, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)
        send(test_pid, {:users_page, current_page, conn.query_params})

        response =
          case current_page do
            0 ->
              %{
                "users" => [active_google_user(%{"id" => "user1"})],
                "nextPageToken" => "page2_token"
              }

            1 ->
              %{
                "users" => [active_google_user(%{"id" => "user2"})],
                "nextPageToken" => "page3_token"
              }

            2 ->
              %{"users" => [active_google_user(%{"id" => "user3"})]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [
               [%{"id" => "user1"}],
               [%{"id" => "user2"}],
               [%{"id" => "user3"}]
             ] = result

      assert_receive {:users_page, 0, page1_params}
      assert page1_params["query"] == "isSuspended=false isArchived=false"
      refute Map.has_key?(page1_params, "pageToken")

      assert_receive {:users_page, 1, page2_params}
      assert page2_params["query"] == "isSuspended=false isArchived=false"
      assert page2_params["pageToken"] == "page2_token"

      assert_receive {:users_page, 2, page3_params}
      assert page3_params["query"] == "isSuspended=false isArchived=false"
      assert page3_params["pageToken"] == "page3_token"
    end

    test "returns error on non-200 response" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 403}}] = result
    end

    test "returns error when users key is missing" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"kind" => "admin#directory#users"})
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, {:missing_key, message, _body}}] = result
      assert message =~ "users"
    end

    test "returns error when users key is not a list" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => "not_a_list"})
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, {:invalid_response, message, _body}}] = result
      assert message =~ "users is not a list"
    end

    test "returns error on network failure" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, %Req.TransportError{reason: :econnrefused}}] = result
    end

    test "filters suspended and archived users from returned pages" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"}),
            %{"id" => "user2", "primaryEmail" => "user2@example.com", "suspended" => true},
            %{"id" => "user3", "primaryEmail" => "user3@example.com", "archived" => true}
          ]
        })
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}]] = result
    end

    test "logs and skips users missing suspended or archived flags" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "kind" => "admin#directory#users",
          "users" => [
            %{"id" => "user1", "primaryEmail" => "user1@example.com"},
            active_google_user(%{
              "id" => "user2",
              "primaryEmail" => "user2@example.com"
            })
          ]
        })
      end)

      log =
        capture_log(fn ->
          result =
            APIClient.stream_users(@test_access_token, @test_domain)
            |> Enum.to_list()

          assert [[%{"id" => "user2"}]] = result
        end)

      assert log =~ "Skipping Google user with missing suspended/archived flags"
      assert log =~ "user1"
    end
  end

  describe "stream_groups/2" do
    test "streams a single page of groups" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:groups_request, conn})

        Req.Test.json(conn, %{
          "kind" => "admin#directory#groups",
          "groups" => [
            %{"id" => "group1", "name" => "Engineering"},
            %{"id" => "group2", "name" => "Sales"}
          ]
        })
      end)

      result =
        APIClient.stream_groups(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "group1"}, %{"id" => "group2"}]] = result

      assert_receive {:groups_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["customer"] == "my_customer"
      assert conn.query_params["domain"] == @test_domain
      assert conn.query_params["maxResults"] == "200"
    end

    test "streams multiple pages using nextPageToken" do
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        response =
          case current_page do
            0 -> %{"groups" => [%{"id" => "group1"}], "nextPageToken" => "next"}
            1 -> %{"groups" => [%{"id" => "group2"}]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_groups(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "group1"}], [%{"id" => "group2"}]] = result
    end

    test "returns empty list when groups key is missing (e.g. filtered query with no matches)" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{})
      end)

      result =
        APIClient.stream_groups(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[]] = result
    end
  end

  describe "stream_group_members/2" do
    test "streams a single page of direct members" do
      test_pid = self()
      group_key = "group123"

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:members_request, conn})

        Req.Test.json(conn, %{
          "kind" => "admin#directory#members",
          "members" => [
            %{"id" => "user1", "email" => "user1@example.com", "type" => "USER"},
            %{"id" => "user2", "email" => "user2@example.com", "type" => "USER"},
            %{"id" => "nested_group", "email" => "nested@example.com", "type" => "GROUP"}
          ]
        })
      end)

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}, %{"id" => "user2"}, %{"id" => "nested_group"}]] = result

      assert_receive {:members_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["maxResults"] == "200"
      refute Map.has_key?(conn.query_params, "includeDerivedMembership")
    end

    test "streams multiple pages of members" do
      test_pid = self()
      group_key = "group123"
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)
        send(test_pid, {:members_page, current_page, conn.query_params})

        response =
          case current_page do
            0 ->
              %{"members" => [%{"id" => "user1", "type" => "USER"}], "nextPageToken" => "page2"}

            1 ->
              %{"members" => [%{"id" => "user2", "type" => "USER"}]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}], [%{"id" => "user2"}]] = result

      assert_receive {:members_page, 0, page1_params}
      refute Map.has_key?(page1_params, "includeDerivedMembership")
      refute Map.has_key?(page1_params, "pageToken")

      assert_receive {:members_page, 1, page2_params}
      refute Map.has_key?(page2_params, "includeDerivedMembership")
      assert page2_params["pageToken"] == "page2"
    end

    test "returns empty list when members key is omitted (empty group)" do
      group_key = "empty_group"

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"kind" => "admin#directory#members"})
      end)

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [[]] = result
    end

    test "returns error on non-200 response" do
      group_key = "group123"

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "Group not found"})
      end)

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 404}}] = result
    end
  end

  describe "stream_organization_units/1" do
    test "streams a single page of organization units" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:orgunits_request, conn})

        Req.Test.json(conn, %{
          "kind" => "admin#directory#org_units",
          "organizationUnits" => [
            %{"orgUnitId" => "ou1", "name" => "Engineering", "orgUnitPath" => "/Engineering"},
            %{"orgUnitId" => "ou2", "name" => "Sales", "orgUnitPath" => "/Sales"}
          ]
        })
      end)

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [[%{"orgUnitId" => "ou1"}, %{"orgUnitId" => "ou2"}]] = result

      assert_receive {:orgunits_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["type"] == "all"
    end

    test "streams multiple pages of organization units" do
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        response =
          case current_page do
            0 ->
              %{
                "organizationUnits" => [%{"orgUnitId" => "ou1", "name" => "Eng"}],
                "nextPageToken" => "next"
              }

            1 ->
              %{"organizationUnits" => [%{"orgUnitId" => "ou2", "name" => "Sales"}]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [[%{"orgUnitId" => "ou1"}], [%{"orgUnitId" => "ou2"}]] = result
    end

    test "returns empty list when organizationUnits key is omitted (no org units)" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"kind" => "admin#directory#org_units"})
      end)

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [[]] = result
    end

    test "returns error on non-200 response" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "Internal error"})
      end)

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 500}}] = result
    end
  end

  describe "stream_organization_unit_members/2" do
    test "streams users from a specific org unit" do
      test_pid = self()
      org_unit_path = "/Engineering"

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:org_unit_users_request, conn})

        Req.Test.json(conn, %{
          "kind" => "admin#directory#users",
          "users" => [
            active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"}),
            active_google_user(%{"id" => "user2", "primaryEmail" => "user2@example.com"})
          ]
        })
      end)

      result =
        APIClient.stream_organization_unit_members(@test_access_token, org_unit_path)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}, %{"id" => "user2"}]] = result

      assert_receive {:org_unit_users_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["customer"] == "my_customer"

      assert conn.query_params["query"] ==
               "orgUnitPath='/Engineering' isSuspended=false isArchived=false"

      assert conn.query_params["maxResults"] == "500"
      assert conn.query_params["projection"] == "full"
    end

    test "streams multiple pages of org unit users" do
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        response =
          case current_page do
            0 ->
              %{
                "users" => [active_google_user(%{"id" => "user1"})],
                "nextPageToken" => "next_page"
              }

            1 ->
              %{"users" => [active_google_user(%{"id" => "user2"})]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_organization_unit_members(@test_access_token, "/Sales")
        |> Enum.to_list()

      assert [[%{"id" => "user1"}], [%{"id" => "user2"}]] = result
    end

    test "returns empty list when no users in org unit" do
      # Google omits the "users" key entirely when no users match the query
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "etag" =>
            "\"a38212e01d6f419c9bd303b304a99e9b-R4oCxwN6CJX5V4YS861KQ8/qMN0tU6EFQXmCVIrUh8pyH16GNQ\"",
          "kind" => "admin#directory#users"
        })
      end)

      result =
        APIClient.stream_organization_unit_members(@test_access_token, "/EmptyOrgUnit")
        |> Enum.to_list()

      assert [[]] = result
    end

    test "returns error on non-200 response" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Permission denied"})
      end)

      result =
        APIClient.stream_organization_unit_members(@test_access_token, "/Engineering")
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 403}}] = result
    end

    test "filters suspended and archived org unit users from returned pages" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{
          "users" => [
            active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"}),
            %{"id" => "user2", "primaryEmail" => "user2@example.com", "suspended" => true},
            %{"id" => "user3", "primaryEmail" => "user3@example.com", "archived" => true}
          ]
        })
      end)

      result =
        APIClient.stream_organization_unit_members(@test_access_token, "/Engineering")
        |> Enum.to_list()

      assert [[%{"id" => "user1"}]] = result
    end
  end

  describe "batch_get_users/2" do
    test "returns empty list when user_ids is empty" do
      assert {:ok, []} = APIClient.batch_get_users(@test_access_token, [])
    end

    test "uses configured batch endpoint when provided" do
      custom_endpoint = "https://batch.googleapis.test/custom-batch"

      # Use a process-scoped override so concurrent async tests don't clobber
      # each other's global Application env for Portal.Google.APIClient.
      Portal.Config.put_env_override(:portal, APIClient, batch_endpoint: custom_endpoint)

      Req.Test.expect(APIClient, fn conn ->
        assert conn.host == "batch.googleapis.test"
        assert conn.request_path == "/custom-batch"

        boundary = "custom_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 200 OK",
             JSON.encode!(
               active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"})
             )}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, [%{"id" => "user1", "primaryEmail" => "user1@example.com"}]} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "parses multipart responses with quoted boundary values" do
      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/batch")

        boundary = "quoted_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 200 OK",
             JSON.encode!(
               active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"})
             )}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=\"#{boundary}\"")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, [%{"id" => "user1", "primaryEmail" => "user1@example.com"}]} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "returns error for parts with malformed HTTP status line" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "malformed_status_boundary"

        body =
          build_batch_body(boundary, [
            {"NOT-HTTP", JSON.encode!(%{"id" => "user1", "primaryEmail" => "user1@example.com"})}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, %Req.Response{status: 502}} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "skips 404 users in batch response" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "not_found_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 404 Not Found", JSON.encode!(%{"error" => %{"message" => "not found"}})}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, []} = APIClient.batch_get_users(@test_access_token, ["deleted-user"])
    end

    test "handles iodata response body for multipart parsing" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "iodata_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 200 OK",
             JSON.encode!(
               active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"})
             )}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, [body])
      end)

      assert {:ok, [%{"id" => "user1", "primaryEmail" => "user1@example.com"}]} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "returns error for non-200 batch response" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server error"})
      end)

      assert {:error, %Req.Response{status: 500}} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "returns error for non-404 per-part status in batch response" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "forbidden_part_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 403 Forbidden", JSON.encode!(%{"error" => %{"message" => "forbidden"}})}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, %Req.Response{status: 403}} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "returns transport error for batch request failure" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "filters suspended and archived users from batch results" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "filtered_users_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 200 OK",
             JSON.encode!(
               active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"})
             )},
            {"HTTP/1.1 200 OK",
             JSON.encode!(%{
               "id" => "user2",
               "primaryEmail" => "user2@example.com",
               "suspended" => true
             })},
            {"HTTP/1.1 200 OK",
             JSON.encode!(%{
               "id" => "user3",
               "primaryEmail" => "user3@example.com",
               "archived" => true
             })}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, users} =
               APIClient.batch_get_users(@test_access_token, ["user1", "user2", "user3"])

      assert Enum.map(users, & &1["id"]) == ["user1"]
    end

    test "logs and skips batch users missing suspended or archived flags" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "missing_flags_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 200 OK",
             JSON.encode!(%{"id" => "user1", "primaryEmail" => "user1@example.com"})},
            {"HTTP/1.1 200 OK",
             JSON.encode!(
               active_google_user(%{"id" => "user2", "primaryEmail" => "user2@example.com"})
             )}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      log =
        capture_log(fn ->
          assert {:ok, users} = APIClient.batch_get_users(@test_access_token, ["user1", "user2"])
          assert Enum.map(users, & &1["id"]) == ["user2"]
        end)

      assert log =~ "Skipping Google user with missing suspended/archived flags"
      assert log =~ "user1"
    end

    test "halts on chunk error after first successful chunk" do
      counter = :atomics.new(1, [])

      Req.Test.expect(APIClient, 2, fn conn ->
        call_idx = :atomics.get(counter, 1)
        :atomics.put(counter, 1, call_idx + 1)

        case call_idx do
          0 ->
            boundary = "first_chunk"

            body =
              build_batch_body(boundary, [
                {"HTTP/1.1 200 OK",
                 JSON.encode!(
                   active_google_user(%{"id" => "user1", "primaryEmail" => "user1@example.com"})
                 )}
              ])

            conn
            |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
            |> Plug.Conn.send_resp(200, body)

          _ ->
            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"error" => "unavailable"})
        end
      end)

      user_ids = Enum.map(1..101, &"user-#{&1}")

      assert {:error, %Req.Response{status: 503}} =
               APIClient.batch_get_users(@test_access_token, user_ids)
    end

    test "raises when multipart boundary is missing from content type" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed")
        |> Plug.Conn.send_resp(200, "--irrelevant--")
      end)

      assert_raise RuntimeError, ~r/Could not extract multipart boundary/, fn ->
        APIClient.batch_get_users(@test_access_token, ["user1"])
      end
    end

    test "returns error for malformed multipart parts" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "malformed_part_boundary"

        body =
          "--#{boundary}\r\nContent-Type: application/http\r\n\r\nmalformed\r\n--#{boundary}--"

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, %Req.Response{status: 502}} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end

    test "returns error for batch parts with invalid JSON payload" do
      Req.Test.expect(APIClient, fn conn ->
        boundary = "invalid_json_boundary"

        body =
          build_batch_body(boundary, [
            {"HTTP/1.1 200 OK", "not-json"}
          ])

        conn
        |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, %Req.Response{status: 502}} =
               APIClient.batch_get_users(@test_access_token, ["user1"])
    end
  end

  describe "pagination edge cases" do
    test "handles empty result list correctly for users" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"users" => []})
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[]] = result
    end

    test "stops pagination when error occurs mid-stream" do
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        case current_page do
          0 ->
            Req.Test.json(conn, %{
              "users" => [active_google_user(%{"id" => "user1"})],
              "nextPageToken" => "page2"
            })

          1 ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "Server error"})
        end
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}], {:error, %Req.Response{status: 500}}] = result
    end

    test "preserves original query parameters when paginating" do
      test_pid = self()
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)
        send(test_pid, {:page_params, current_page, conn.query_params})

        response =
          case current_page do
            0 ->
              %{
                "users" => [active_google_user(%{"id" => "user1"})],
                "nextPageToken" => "token123"
              }

            1 ->
              %{"users" => [active_google_user(%{"id" => "user2"})]}
          end

        Req.Test.json(conn, response)
      end)

      APIClient.stream_users(@test_access_token, @test_domain)
      |> Enum.to_list()

      assert_receive {:page_params, 0, page1_params}
      assert page1_params["customer"] == "my_customer"
      assert page1_params["domain"] == @test_domain
      assert page1_params["maxResults"] == "500"
      assert page1_params["projection"] == "full"
      assert page1_params["query"] == "isSuspended=false isArchived=false"
      refute Map.has_key?(page1_params, "pageToken")

      assert_receive {:page_params, 1, page2_params}
      assert page2_params["customer"] == "my_customer"
      assert page2_params["domain"] == @test_domain
      assert page2_params["maxResults"] == "500"
      assert page2_params["projection"] == "full"
      assert page2_params["query"] == "isSuspended=false isArchived=false"
      assert page2_params["pageToken"] == "token123"
    end
  end

  # Helper functions

  defp build_batch_body(boundary, parts) do
    encoded_parts =
      Enum.map(parts, fn {status_line, json_body} ->
        "--#{boundary}\r\nContent-Type: application/http\r\n\r\n#{status_line}\r\nContent-Type: application/json\r\n\r\n#{json_body}\r\n"
      end)

    Enum.join(encoded_parts, "") <> "--#{boundary}--"
  end

  defp active_google_user(attrs) do
    attrs
    |> Map.put_new("suspended", false)
    |> Map.put_new("archived", false)
  end

  defp assert_authorization_header(conn, expected_token) do
    auth_header =
      Enum.find(conn.req_headers, fn {key, _} -> key == "authorization" end)

    assert auth_header, "Expected authorization header to be present"
    {_, value} = auth_header
    assert value == "Bearer #{expected_token}"
  end
end
