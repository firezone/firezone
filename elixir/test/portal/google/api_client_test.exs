defmodule Portal.Google.APIClientTest do
  use ExUnit.Case, async: true

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
    bypass = Bypass.open()
    override_endpoint_url("http://localhost:#{bypass.port}")
    %{bypass: bypass}
  end

  describe "get_access_token/2" do
    test "exchanges JWT for access token", %{bypass: bypass} do
      override_token_endpoint("http://localhost:#{bypass.port}/token")

      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_request, body, conn})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{
            "access_token" => "returned_access_token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
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

    test "returns error on network failure", %{bypass: bypass} do
      override_token_endpoint("http://localhost:#{bypass.port}/token")
      Bypass.down(bypass)

      key = %{
        "client_email" => "test@project.iam.gserviceaccount.com",
        "private_key" => @test_private_key
      }

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               APIClient.get_access_token("admin@example.com", key)
    end
  end

  describe "get_customer/1" do
    test "fetches customer information", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/customers/my_customer", fn conn ->
        send(test_pid, {:customer_request, conn})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{
            "kind" => "admin#directory#customer",
            "id" => "C12345678",
            "customerDomain" => "example.com"
          })
        )
      end)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.get_customer(@test_access_token)

      assert body["id"] == "C12345678"

      assert_receive {:customer_request, conn}
      assert_authorization_header(conn, @test_access_token)
    end
  end

  describe "test_connection/2" do
    test "returns :ok when all endpoints are accessible", %{bypass: bypass} do
      mock_test_endpoint(bypass, "/admin/directory/v1/users", 200)
      mock_test_endpoint(bypass, "/admin/directory/v1/groups", 200)
      mock_test_endpoint(bypass, "/admin/directory/v1/customer/my_customer/orgunits", 200)

      assert :ok = APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "returns error when users endpoint fails", %{bypass: bypass} do
      mock_test_endpoint(bypass, "/admin/directory/v1/users", 403)

      assert {:ok, %Req.Response{status: 403}} =
               APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "returns error when groups endpoint fails", %{bypass: bypass} do
      mock_test_endpoint(bypass, "/admin/directory/v1/users", 200)
      mock_test_endpoint(bypass, "/admin/directory/v1/groups", 403)

      assert {:ok, %Req.Response{status: 403}} =
               APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "returns error when org_units endpoint fails", %{bypass: bypass} do
      mock_test_endpoint(bypass, "/admin/directory/v1/users", 200)
      mock_test_endpoint(bypass, "/admin/directory/v1/groups", 200)
      mock_test_endpoint(bypass, "/admin/directory/v1/customer/my_customer/orgunits", 403)

      assert {:ok, %Req.Response{status: 403}} =
               APIClient.test_connection(@test_access_token, @test_domain)
    end

    test "verifies correct query parameters are sent", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:users_query, conn.query_params})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Bypass.expect(bypass, "GET", "/admin/directory/v1/groups", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:groups_query, conn.query_params})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Bypass.expect(bypass, "GET", "/admin/directory/v1/customer/my_customer/orgunits", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:orgunits_query, conn.query_params})
        Plug.Conn.send_resp(conn, 200, "{}")
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
    test "streams a single page of users", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:users_request, conn})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{
            "kind" => "admin#directory#users",
            "users" => [
              %{"id" => "user1", "primaryEmail" => "user1@example.com"},
              %{"id" => "user2", "primaryEmail" => "user2@example.com"}
            ]
          })
        )
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
    end

    test "streams multiple pages using nextPageToken", %{bypass: bypass} do
      test_pid = self()
      page_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)
        send(test_pid, {:users_page, current_page, conn.query_params})

        response =
          case current_page do
            0 ->
              %{
                "users" => [%{"id" => "user1"}],
                "nextPageToken" => "page2_token"
              }

            1 ->
              %{
                "users" => [%{"id" => "user2"}],
                "nextPageToken" => "page3_token"
              }

            2 ->
              %{"users" => [%{"id" => "user3"}]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
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
      refute Map.has_key?(page1_params, "pageToken")

      assert_receive {:users_page, 1, page2_params}
      assert page2_params["pageToken"] == "page2_token"

      assert_receive {:users_page, 2, page3_params}
      assert page3_params["pageToken"] == "page3_token"
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      # Use stub instead of expect_once since Req may retry on certain status codes
      Bypass.stub(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, JSON.encode!(%{"error" => "Forbidden"}))
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 403}}] = result
    end

    test "returns error when users key is missing", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(%{"kind" => "admin#directory#users"}))
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, {:missing_key, message, _body}}] = result
      assert message =~ "users"
    end

    test "returns error when users key is not a list", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(%{"users" => "not_a_list"}))
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, {:invalid_response, message, _body}}] = result
      assert message =~ "users is not a list"
    end

    test "returns error on network failure", %{bypass: bypass} do
      Bypass.down(bypass)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, %Req.TransportError{reason: :econnrefused}}] = result
    end
  end

  describe "stream_groups/2" do
    test "streams a single page of groups", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/groups", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:groups_request, conn})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{
            "kind" => "admin#directory#groups",
            "groups" => [
              %{"id" => "group1", "name" => "Engineering"},
              %{"id" => "group2", "name" => "Sales"}
            ]
          })
        )
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

    test "streams multiple pages using nextPageToken", %{bypass: bypass} do
      page_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/admin/directory/v1/groups", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        response =
          case current_page do
            0 -> %{"groups" => [%{"id" => "group1"}], "nextPageToken" => "next"}
            1 -> %{"groups" => [%{"id" => "group2"}]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
      end)

      result =
        APIClient.stream_groups(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "group1"}], [%{"id" => "group2"}]] = result
    end

    test "returns error when groups key is missing", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/groups", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(%{}))
      end)

      result =
        APIClient.stream_groups(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [{:error, {:missing_key, message, _body}}] = result
      assert message =~ "groups"
    end
  end

  describe "stream_group_members/2" do
    test "streams a single page of members with includeDerivedMembership", %{bypass: bypass} do
      test_pid = self()
      group_key = "group123"

      Bypass.expect_once(
        bypass,
        "GET",
        "/admin/directory/v1/groups/#{group_key}/members",
        fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:members_request, conn})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            JSON.encode!(%{
              "kind" => "admin#directory#members",
              "members" => [
                %{"id" => "user1", "email" => "user1@example.com", "type" => "USER"},
                %{"id" => "user2", "email" => "user2@example.com", "type" => "USER"},
                %{"id" => "nested_group", "email" => "nested@example.com", "type" => "GROUP"}
              ]
            })
          )
        end
      )

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}, %{"id" => "user2"}, %{"id" => "nested_group"}]] = result

      assert_receive {:members_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["maxResults"] == "200"
      assert conn.query_params["includeDerivedMembership"] == "true"
    end

    test "streams multiple pages of members", %{bypass: bypass} do
      test_pid = self()
      group_key = "group123"
      page_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/admin/directory/v1/groups/#{group_key}/members", fn conn ->
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

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
      end)

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}], [%{"id" => "user2"}]] = result

      assert_receive {:members_page, 0, page1_params}
      assert page1_params["includeDerivedMembership"] == "true"
      refute Map.has_key?(page1_params, "pageToken")

      assert_receive {:members_page, 1, page2_params}
      assert page2_params["includeDerivedMembership"] == "true"
      assert page2_params["pageToken"] == "page2"
    end

    test "returns empty list when members key is omitted (empty group)", %{bypass: bypass} do
      group_key = "empty_group"

      Bypass.expect_once(
        bypass,
        "GET",
        "/admin/directory/v1/groups/#{group_key}/members",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, JSON.encode!(%{"kind" => "admin#directory#members"}))
        end
      )

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [[]] = result
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      group_key = "group123"

      # Use stub instead of expect_once since Req may retry on certain status codes
      Bypass.stub(bypass, "GET", "/admin/directory/v1/groups/#{group_key}/members", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, JSON.encode!(%{"error" => "Group not found"}))
      end)

      result =
        APIClient.stream_group_members(@test_access_token, group_key)
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 404}}] = result
    end
  end

  describe "stream_organization_units/1" do
    test "streams a single page of organization units", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(
        bypass,
        "GET",
        "/admin/directory/v1/customer/my_customer/orgunits",
        fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:orgunits_request, conn})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            JSON.encode!(%{
              "kind" => "admin#directory#org_units",
              "organizationUnits" => [
                %{"orgUnitId" => "ou1", "name" => "Engineering", "orgUnitPath" => "/Engineering"},
                %{"orgUnitId" => "ou2", "name" => "Sales", "orgUnitPath" => "/Sales"}
              ]
            })
          )
        end
      )

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [[%{"orgUnitId" => "ou1"}, %{"orgUnitId" => "ou2"}]] = result

      assert_receive {:orgunits_request, conn}
      assert_authorization_header(conn, @test_access_token)
      assert conn.query_params["type"] == "all"
    end

    test "streams multiple pages of organization units", %{bypass: bypass} do
      page_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/admin/directory/v1/customer/my_customer/orgunits", fn conn ->
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

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
      end)

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [[%{"orgUnitId" => "ou1"}], [%{"orgUnitId" => "ou2"}]] = result
    end

    test "returns empty list when organizationUnits key is omitted (no org units)", %{
      bypass: bypass
    } do
      Bypass.expect_once(
        bypass,
        "GET",
        "/admin/directory/v1/customer/my_customer/orgunits",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, JSON.encode!(%{"kind" => "admin#directory#org_units"}))
        end
      )

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [[]] = result
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      # Use stub instead of expect_once since Req may retry on 5xx status codes
      Bypass.stub(bypass, "GET", "/admin/directory/v1/customer/my_customer/orgunits", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, JSON.encode!(%{"error" => "Internal error"}))
      end)

      result =
        APIClient.stream_organization_units(@test_access_token)
        |> Enum.to_list()

      assert [{:error, %Req.Response{status: 500}}] = result
    end
  end

  describe "pagination edge cases" do
    test "handles empty result list correctly for users", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(%{"users" => []}))
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[]] = result
    end

    test "stops pagination when error occurs mid-stream", %{bypass: bypass} do
      # Use stub to handle Req's automatic retries on 5xx errors
      Bypass.stub(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        # First request (no pageToken) returns success with nextPageToken
        # Subsequent requests (with pageToken) return 500 error
        case conn.query_params["pageToken"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              JSON.encode!(%{
                "users" => [%{"id" => "user1"}],
                "nextPageToken" => "page2"
              })
            )

          _page_token ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, JSON.encode!(%{"error" => "Server error"}))
        end
      end)

      result =
        APIClient.stream_users(@test_access_token, @test_domain)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}], {:error, %Req.Response{status: 500}}] = result
    end

    test "preserves original query parameters when paginating", %{bypass: bypass} do
      test_pid = self()
      page_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/admin/directory/v1/users", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)
        send(test_pid, {:page_params, current_page, conn.query_params})

        response =
          case current_page do
            0 -> %{"users" => [%{"id" => "user1"}], "nextPageToken" => "token123"}
            1 -> %{"users" => [%{"id" => "user2"}]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
      end)

      APIClient.stream_users(@test_access_token, @test_domain)
      |> Enum.to_list()

      assert_receive {:page_params, 0, page1_params}
      assert page1_params["customer"] == "my_customer"
      assert page1_params["domain"] == @test_domain
      assert page1_params["maxResults"] == "500"
      assert page1_params["projection"] == "full"
      refute Map.has_key?(page1_params, "pageToken")

      assert_receive {:page_params, 1, page2_params}
      assert page2_params["customer"] == "my_customer"
      assert page2_params["domain"] == @test_domain
      assert page2_params["maxResults"] == "500"
      assert page2_params["projection"] == "full"
      assert page2_params["pageToken"] == "token123"
    end
  end

  # Helper functions

  defp mock_test_endpoint(bypass, path, status) do
    Bypass.expect(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, "{}")
    end)
  end

  defp assert_authorization_header(conn, expected_token) do
    auth_header =
      Enum.find(conn.req_headers, fn {key, _} -> key == "authorization" end)

    assert auth_header, "Expected authorization header to be present"
    {_, value} = auth_header
    assert value == "Bearer #{expected_token}"
  end

  defp override_endpoint_url(url) do
    config = Portal.Config.fetch_env!(:portal, APIClient)
    config = Keyword.put(config, :endpoint, url)
    Portal.Config.put_env_override(:portal, APIClient, config)
  end

  defp override_token_endpoint(url) do
    config = Portal.Config.fetch_env!(:portal, APIClient)
    config = Keyword.put(config, :token_endpoint, url)
    Portal.Config.put_env_override(:portal, APIClient, config)
  end
end
