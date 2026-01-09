defmodule Portal.Entra.APIClientTest do
  use ExUnit.Case, async: true

  alias Portal.Entra.APIClient

  @test_tenant_id "12345678-1234-1234-1234-123456789012"
  @test_access_token "test_access_token_123"
  @test_client_id "test_client_id"

  setup do
    Req.Test.stub(APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    :ok
  end

  describe "get_access_token/1" do
    test "requests access token using client credentials flow" do
      test_pid = self()
      config = Portal.Config.get_env(:portal, APIClient)

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.ends_with?(conn.request_path, "/oauth2/v2.0/token")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_request, body, conn})

        Req.Test.json(conn, %{
          "access_token" => "returned_access_token",
          "token_type" => "Bearer",
          "expires_in" => 3600
        })
      end)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.get_access_token(@test_tenant_id)

      assert body["access_token"] == "returned_access_token"

      assert_receive {:token_request, request_body, conn}
      assert {"content-type", "application/x-www-form-urlencoded"} in conn.req_headers

      params = URI.decode_query(request_body)
      assert params["grant_type"] == "client_credentials"
      assert params["scope"] == "https://graph.microsoft.com/.default"
      assert params["client_id"] == config[:client_id]
      assert params["client_secret"] == config[:client_secret]
    end

    test "returns error on network failure" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               APIClient.get_access_token(@test_tenant_id)
    end

    test "returns 401 response on authentication failure" do
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      assert {:ok, %Req.Response{status: 401}} =
               APIClient.get_access_token(@test_tenant_id)
    end
  end

  describe "get_service_principal/2" do
    test "fetches service principal by client id" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1.0/servicePrincipals"

        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:service_principal_request, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [
            %{"id" => "sp_id_123", "appId" => @test_client_id}
          ]
        })
      end)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.get_service_principal(@test_access_token, @test_client_id)

      assert [%{"id" => "sp_id_123"}] = body["value"]

      assert_receive {:service_principal_request, query_params}
      assert query_params["$filter"] == "appId eq '#{@test_client_id}'"
      assert query_params["$select"] == "id,appId"
    end
  end

  describe "list_app_role_assignments/2" do
    test "fetches app role assignments with limit of 1" do
      test_pid = self()
      service_principal_id = "sp_123"

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "GET"

        assert conn.request_path ==
                 "/v1.0/servicePrincipals/#{service_principal_id}/appRoleAssignedTo"

        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:assignments_request, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [
            %{
              "id" => "assignment1",
              "principalId" => "user_123",
              "principalType" => "User",
              "principalDisplayName" => "Test User"
            }
          ]
        })
      end)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.list_app_role_assignments(@test_access_token, service_principal_id)

      assert [%{"id" => "assignment1"}] = body["value"]

      assert_receive {:assignments_request, query_params}
      assert query_params["$top"] == "1"
      assert query_params["$select"] == "id,principalId,principalType,principalDisplayName"
    end
  end

  describe "stream_app_role_assignments/2" do
    test "streams a single page of app role assignments" do
      test_pid = self()
      service_principal_id = "sp_123"

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:assignments_page, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [
            %{"principalId" => "user1", "principalType" => "User"},
            %{"principalId" => "group1", "principalType" => "Group"}
          ]
        })
      end)

      result =
        APIClient.stream_app_role_assignments(@test_access_token, service_principal_id)
        |> Enum.to_list()

      assert [
               [%{"principalId" => "user1"}, %{"principalId" => "group1"}]
             ] = result

      assert_receive {:assignments_page, query_params}
      assert query_params["$top"] == "999"
    end

    test "streams multiple pages using @odata.nextLink" do
      test_pid = self()
      service_principal_id = "sp_123"
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)
        send(test_pid, {:page, current_page})

        response =
          case current_page do
            0 ->
              %{
                "value" => [%{"principalId" => "user1"}],
                "@odata.nextLink" =>
                  "https://graph.microsoft.com/v1.0/servicePrincipals/#{service_principal_id}/appRoleAssignedTo?$top=999&$skiptoken=abc123"
              }

            1 ->
              %{"value" => [%{"principalId" => "user2"}]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_app_role_assignments(@test_access_token, service_principal_id)
        |> Enum.to_list()

      assert [
               [%{"principalId" => "user1"}],
               [%{"principalId" => "user2"}]
             ] = result

      assert_receive {:page, 0}
      assert_receive {:page, 1}
    end

    test "returns error when value key is missing from response" do
      service_principal_id = "sp_123"

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{})
      end)

      result =
        APIClient.stream_app_role_assignments(@test_access_token, service_principal_id)
        |> Enum.to_list()

      assert [{:error, {:missing_key, message, _body}}] = result
      assert message =~ "value"
    end

    test "returns error when response value is not a list" do
      service_principal_id = "sp_123"

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"value" => "not_a_list"})
      end)

      result =
        APIClient.stream_app_role_assignments(@test_access_token, service_principal_id)
        |> Enum.to_list()

      assert [{:error, {:invalid_response, message, _body}}] = result
      assert message =~ "value is not a list"
    end
  end

  describe "stream_groups/1" do
    test "streams a single page of groups" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:groups_request, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [
            %{"id" => "group1", "displayName" => "Engineering"},
            %{"id" => "group2", "displayName" => "Sales"}
          ]
        })
      end)

      result =
        APIClient.stream_groups(@test_access_token)
        |> Enum.to_list()

      assert [[%{"id" => "group1"}, %{"id" => "group2"}]] = result

      assert_receive {:groups_request, query_params}
      assert query_params["$top"] == "999"
      assert query_params["$select"] == "id,displayName"
    end

    test "handles empty groups list" do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, %{"value" => []})
      end)

      result =
        APIClient.stream_groups(@test_access_token)
        |> Enum.to_list()

      assert [[]] = result
    end
  end

  describe "stream_group_transitive_members/2" do
    test "streams transitive members of a group" do
      test_pid = self()
      group_id = "group_123"

      Req.Test.expect(APIClient, fn conn ->
        # Verify the transitive members endpoint is being called
        assert conn.method == "GET"
        assert conn.request_path == "/v1.0/groups/#{group_id}/transitiveMembers"

        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:members_request, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [
            %{
              "id" => "user1",
              "displayName" => "User One",
              "mail" => "user1@example.com",
              "userPrincipalName" => "user1@example.com",
              "givenName" => "User",
              "surname" => "One",
              "aboutMe" => "Test user"
            },
            %{
              "id" => "user2",
              "displayName" => "User Two",
              "mail" => "user2@example.com",
              "userPrincipalName" => "user2@example.com"
            }
          ]
        })
      end)

      result =
        APIClient.stream_group_transitive_members(@test_access_token, group_id)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}, %{"id" => "user2"}]] = result

      assert_receive {:members_request, query_params}
      assert query_params["$top"] == "999"

      assert query_params["$select"] ==
               "id,displayName,mail,userPrincipalName,givenName,surname,aboutMe"
    end

    test "streams multiple pages of members" do
      group_id = "group_123"
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        # Verify the transitive members endpoint is being called
        assert conn.request_path =~ "/groups/#{group_id}/transitiveMembers"

        response =
          case current_page do
            0 ->
              %{
                "value" => [%{"id" => "user1"}],
                "@odata.nextLink" =>
                  "https://graph.microsoft.com/v1.0/groups/#{group_id}/transitiveMembers?$skiptoken=xyz"
              }

            1 ->
              %{"value" => [%{"id" => "user2"}]}
          end

        Req.Test.json(conn, response)
      end)

      result =
        APIClient.stream_group_transitive_members(@test_access_token, group_id)
        |> Enum.to_list()

      assert [[%{"id" => "user1"}], [%{"id" => "user2"}]] = result
    end
  end

  describe "batch_get_users/2" do
    test "fetches multiple users using batch API" do
      test_pid = self()
      user_ids = ["user1", "user2", "user3"]

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "POST"
        assert String.ends_with?(conn.request_path, "/$batch")

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        batch_request = JSON.decode!(body)
        send(test_pid, {:batch_request, batch_request})

        batch_response = %{
          "responses" => [
            %{
              "id" => "1",
              "status" => 200,
              "body" => %{
                "id" => "user1",
                "displayName" => "User One",
                "mail" => "user1@example.com"
              }
            },
            %{
              "id" => "2",
              "status" => 200,
              "body" => %{
                "id" => "user2",
                "displayName" => "User Two",
                "mail" => "user2@example.com"
              }
            },
            %{
              "id" => "3",
              "status" => 200,
              "body" => %{
                "id" => "user3",
                "displayName" => "User Three",
                "mail" => "user3@example.com"
              }
            }
          ]
        }

        Req.Test.json(conn, batch_response)
      end)

      assert {:ok, users} = APIClient.batch_get_users(@test_access_token, user_ids)

      assert length(users) == 3
      assert Enum.at(users, 0)["id"] == "user1"
      assert Enum.at(users, 1)["id"] == "user2"
      assert Enum.at(users, 2)["id"] == "user3"

      assert_receive {:batch_request, batch_request}
      assert length(batch_request["requests"]) == 3
      assert Enum.at(batch_request["requests"], 0)["method"] == "GET"
      assert Enum.at(batch_request["requests"], 0)["url"] =~ "/users/user1"
    end

    test "handles partial failures in batch request" do
      user_ids = ["user1", "user2"]

      Req.Test.expect(APIClient, fn conn ->
        batch_response = %{
          "responses" => [
            %{
              "id" => "1",
              "status" => 200,
              "body" => %{
                "id" => "user1",
                "displayName" => "User One",
                "mail" => "user1@example.com"
              }
            },
            %{
              "id" => "2",
              "status" => 404,
              "body" => %{"error" => "User not found"}
            }
          ]
        }

        Req.Test.json(conn, batch_response)
      end)

      assert {:ok, users} = APIClient.batch_get_users(@test_access_token, user_ids)
      assert length(users) == 1
      assert Enum.at(users, 0)["id"] == "user1"
    end

    test "returns error when all batch requests fail" do
      user_ids = ["user1", "user2"]

      Req.Test.expect(APIClient, fn conn ->
        batch_response = %{
          "responses" => [
            %{
              "id" => "1",
              "status" => 404,
              "body" => %{"error" => "User not found"}
            },
            %{
              "id" => "2",
              "status" => 404,
              "body" => %{"error" => "User not found"}
            }
          ]
        }

        Req.Test.json(conn, batch_response)
      end)

      assert {:error, {:batch_all_failed, 404, _body}} =
               APIClient.batch_get_users(@test_access_token, user_ids)
    end

    test "returns error on non-200 batch API response" do
      user_ids = ["user1"]

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "Unauthorized"})
      end)

      assert {:error, {:batch_request_failed, 401, _body}} =
               APIClient.batch_get_users(@test_access_token, user_ids)
    end
  end

  describe "list_users/1" do
    test "fetches users with limit of 1" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:users_request, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [%{"id" => "user1", "displayName" => "Test User"}]
        })
      end)

      assert {:ok, %Req.Response{status: 200}} = APIClient.list_users(@test_access_token)

      assert_receive {:users_request, query_params}
      assert query_params["$top"] == "1"
      assert query_params["$select"] == "id,displayName"
    end
  end

  describe "list_groups/1" do
    test "fetches groups with limit of 1" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:groups_request, conn.query_params})

        Req.Test.json(conn, %{
          "value" => [%{"id" => "group1", "displayName" => "Test Group"}]
        })
      end)

      assert {:ok, %Req.Response{status: 200}} = APIClient.list_groups(@test_access_token)

      assert_receive {:groups_request, query_params}
      assert query_params["$top"] == "1"
      assert query_params["$select"] == "id,displayName"
    end
  end

  describe "test_connection/1" do
    test "returns :ok when all endpoints succeed" do
      Req.Test.expect(APIClient, 2, fn conn ->
        Req.Test.json(conn, %{"value" => [%{"id" => "test"}]})
      end)

      assert :ok = APIClient.test_connection(@test_access_token)
    end

    test "returns error when users endpoint fails" do
      Req.Test.expect(APIClient, fn %Plug.Conn{request_path: "/v1.0/users"} = conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      assert {:ok, %Req.Response{status: 403}} = APIClient.test_connection(@test_access_token)
    end

    test "returns error when groups endpoint fails" do
      # First call to users succeeds
      Req.Test.expect(APIClient, fn %Plug.Conn{request_path: "/v1.0/users"} = conn ->
        Req.Test.json(conn, %{"value" => [%{"id" => "user1"}]})
      end)

      # Second call to groups fails
      Req.Test.expect(APIClient, fn %Plug.Conn{request_path: "/v1.0/groups"} = conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      assert {:ok, %Req.Response{status: 403}} = APIClient.test_connection(@test_access_token)
    end
  end

  describe "get_subscribed_skus/1" do
    test "fetches subscribed SKUs" do
      test_pid = self()

      Req.Test.expect(APIClient, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1.0/subscribedSkus"
        send(test_pid, :skus_request)

        Req.Test.json(conn, %{
          "value" => [
            %{
              "id" => "sku1",
              "skuPartNumber" => "ENTERPRISEPACK",
              "capabilityStatus" => "Enabled"
            }
          ]
        })
      end)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               APIClient.get_subscribed_skus(@test_access_token)

      assert [%{"id" => "sku1"}] = body["value"]
      assert_receive :skus_request
    end
  end

  describe "pagination edge cases" do
    test "stops pagination when error occurs mid-stream" do
      service_principal_id = "sp_123"
      page_count = :counters.new(1, [:atomics])

      Req.Test.expect(APIClient, 2, fn conn ->
        current_page = :counters.get(page_count, 1)
        :counters.add(page_count, 1, 1)

        case current_page do
          0 ->
            Req.Test.json(conn, %{
              "value" => [%{"principalId" => "user1"}],
              "@odata.nextLink" => "https://graph.microsoft.com/v1.0/next"
            })

          1 ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "Server error"})
        end
      end)

      result =
        APIClient.stream_app_role_assignments(@test_access_token, service_principal_id)
        |> Enum.to_list()

      assert [
               [%{"principalId" => "user1"}],
               {:error, %Req.Response{status: 500}}
             ] = result
    end

    test "handles network errors in stream" do
      service_principal_id = "sp_123"

      Req.Test.expect(APIClient, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      result =
        APIClient.stream_app_role_assignments(@test_access_token, service_principal_id)
        |> Enum.to_list()

      assert [{:error, %Req.TransportError{reason: :timeout}}] = result
    end
  end
end
