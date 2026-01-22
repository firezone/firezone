defmodule Portal.Okta.APIClientTest do
  use ExUnit.Case, async: true

  alias Portal.Okta.APIClient

  # Generate a test RSA key pair using JOSE
  @test_jwk JOSE.JWK.generate_key({:rsa, 2048})
  @test_private_key_jwk @test_jwk |> JOSE.JWK.to_map() |> elem(1)

  setup do
    client = %APIClient{
      base_url: "http://test.okta.com",
      client_id: "test_client",
      private_key: @test_private_key_jwk,
      kid: "test_kid"
    }

    %{client: client}
  end

  describe "new/1" do
    test "creates APIClient from Directory struct" do
      directory = %Portal.Okta.Directory{
        okta_domain: "test.okta.com",
        client_id: "test_client_id",
        private_key_jwk: @test_private_key_jwk,
        kid: "test_kid"
      }

      client = APIClient.new(directory)

      assert client.base_url == "https://test.okta.com"
      assert client.client_id == "test_client_id"
      assert client.private_key == @test_private_key_jwk
      assert client.kid == "test_kid"
    end
  end

  describe "new/4" do
    test "creates APIClient from individual parameters" do
      client = APIClient.new("test.okta.com", "client_123", @test_private_key_jwk, "kid_123")

      assert client.base_url == "https://test.okta.com"
      assert client.client_id == "client_123"
      assert client.private_key == @test_private_key_jwk
      assert client.kid == "kid_123"
    end
  end

  describe "dpop_sign/3" do
    test "creates a valid DPoP JWT" do
      claims = %{
        "htm" => "POST",
        "htu" => "https://test.okta.com/oauth2/v1/token",
        "iat" => System.system_time(:second),
        "exp" => System.system_time(:second) + 300,
        "jti" => "test_jti"
      }

      dpop_jwt = APIClient.dpop_sign(claims, @test_private_key_jwk, "test_kid")

      assert is_binary(dpop_jwt)
      assert String.contains?(dpop_jwt, ".")

      # Verify it's a valid JWT by decoding
      jwk = JOSE.JWK.from_map(@test_private_key_jwk)
      {true, %JOSE.JWT{fields: decoded_map}, _} = JOSE.JWT.verify(jwk, dpop_jwt)

      assert decoded_map["htm"] == "POST"
      assert decoded_map["htu"] == "https://test.okta.com/oauth2/v1/token"
      assert decoded_map["jti"] == "test_jti"
    end

    test "includes correct header in DPoP JWT" do
      claims = %{
        "htm" => "GET",
        "htu" => "https://test.okta.com/api/v1/users",
        "iat" => System.system_time(:second),
        "exp" => System.system_time(:second) + 300,
        "jti" => "test_jti_2"
      }

      dpop_jwt = APIClient.dpop_sign(claims, @test_private_key_jwk, "my_kid")

      # Decode header
      [header_b64, _, _] = String.split(dpop_jwt, ".")
      header = header_b64 |> Base.url_decode64!(padding: false) |> JSON.decode!()

      assert header["alg"] == "RS256"
      assert header["typ"] == "dpop+jwt"
      assert header["kid"] == "my_kid"
      assert header["jwk"]["kty"] == "RSA"
    end
  end

  describe "fetch_access_token/2" do
    test "fetches access token with DPoP nonce challenge and retries", %{client: client} do
      test_pid = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(APIClient, fn conn ->
        count = Agent.get_and_update(agent, fn state -> {state, state + 1} end)

        if count == 0 do
          send(test_pid, :initial_request)

          conn
          |> Plug.Conn.put_resp_header("dpop-nonce", "nonce_12345")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(400, JSON.encode!(%{"error" => "use_dpop_nonce"}))
        else
          send(test_pid, :retry_with_nonce)

          response_body = %{
            "access_token" => "token_after_nonce",
            "token_type" => "DPoP",
            "expires_in" => 3600
          }

          Req.Test.json(conn, response_body)
        end
      end)

      assert {:ok, "token_after_nonce"} = APIClient.fetch_access_token(client)
      assert_receive :initial_request
      assert_receive :retry_with_nonce
    end

    test "returns error on failure", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 401, JSON.encode!(%{"error" => "invalid_client"}))
      end)

      assert {:error, %Req.Response{status: 401}} = APIClient.fetch_access_token(client)
    end
  end

  describe "test_connection/2" do
    test "returns :ok when all endpoints succeed", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        # test_endpoint expects non-empty list
        case conn.request_path do
          "/api/v1/groups" -> Req.Test.json(conn, [%{"id" => "group1"}])
          "/api/v1/users" -> Req.Test.json(conn, [%{"id" => "user1"}])
          "/api/v1/apps" -> Req.Test.json(conn, [%{"id" => "app1"}])
          _ -> Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      assert :ok = APIClient.test_connection(client, "test_token")
    end

    test "returns error when an endpoint fails", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        case conn.request_path do
          "/api/v1/groups" ->
            Plug.Conn.send_resp(conn, 403, JSON.encode!(%{"error" => "forbidden"}))

          "/api/v1/users" ->
            Req.Test.json(conn, [%{"id" => "user1"}])

          "/api/v1/apps" ->
            Req.Test.json(conn, [%{"id" => "app1"}])

          _ ->
            Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      assert {:error, %Req.Response{status: 403}} =
               APIClient.test_connection(client, "test_token")
    end

    test "returns error when apps endpoint returns empty list", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        case conn.request_path do
          "/api/v1/apps" -> Req.Test.json(conn, [])
          "/api/v1/users" -> Req.Test.json(conn, [%{"id" => "user1"}])
          "/api/v1/groups" -> Req.Test.json(conn, [%{"id" => "group1"}])
        end
      end)

      assert {:error, :empty, :apps} = APIClient.test_connection(client, "test_token")
    end

    test "returns error when users endpoint returns empty list", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        case conn.request_path do
          "/api/v1/apps" -> Req.Test.json(conn, [%{"id" => "app1"}])
          "/api/v1/users" -> Req.Test.json(conn, [])
          "/api/v1/groups" -> Req.Test.json(conn, [%{"id" => "group1"}])
        end
      end)

      assert {:error, :empty, :users} = APIClient.test_connection(client, "test_token")
    end

    test "returns error when groups endpoint returns empty list", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        case conn.request_path do
          "/api/v1/apps" -> Req.Test.json(conn, [%{"id" => "app1"}])
          "/api/v1/users" -> Req.Test.json(conn, [%{"id" => "user1"}])
          "/api/v1/groups" -> Req.Test.json(conn, [])
        end
      end)

      assert {:error, :empty, :groups} = APIClient.test_connection(client, "test_token")
    end
  end

  describe "introspect_token/2" do
    test "introspects token successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/oauth2/v1/introspect"

        response_body = %{
          "active" => true,
          "client_id" => "test_client",
          "token_type" => "Bearer"
        }

        Req.Test.json(conn, response_body)
      end)

      assert {:ok, %{"active" => true}} = APIClient.introspect_token(client, "test_access_token")
    end

    test "returns error on failure", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 401, JSON.encode!(%{"error" => "invalid_token"}))
      end)

      assert {:error, "unable to introspect"} =
               APIClient.introspect_token(client, "test_access_token")
    end
  end

  describe "list_apps/2" do
    test "fetches all apps successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        apps = [
          %{"id" => "app1", "label" => "App 1"},
          %{"id" => "app2", "label" => "App 2"}
        ]

        Req.Test.json(conn, apps)
      end)

      assert {:ok, apps} = APIClient.list_apps(client, "test_token")
      assert length(apps) == 2
      assert Enum.at(apps, 0)["id"] == "app1"
    end

    test "returns error on failure", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 401, JSON.encode!(%{"error" => "unauthorized"}))
      end)

      assert {:error, "Authentication Error"} = APIClient.list_apps(client, "test_token")
    end
  end

  describe "stream_groups/2" do
    test "streams groups successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        groups = [
          %{"id" => "group1", "profile" => %{"name" => "Group 1"}},
          %{"id" => "group2", "profile" => %{"name" => "Group 2"}}
        ]

        Req.Test.json(conn, groups)
      end)

      results =
        APIClient.stream_groups(client, "test_token")
        |> Enum.map(fn {:ok, group} -> group end)

      assert length(results) == 2
      assert Enum.at(results, 0)["id"] == "group1"
    end

    test "handles pagination", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        # Check if this is the first or second page
        query_params = URI.decode_query(conn.query_string || "")

        if Map.has_key?(query_params, "after") do
          # Second page
          groups = [%{"id" => "group3", "profile" => %{"name" => "Group 3"}}]
          Req.Test.json(conn, groups)
        else
          # First page - include Link header for pagination
          groups = [
            %{"id" => "group1", "profile" => %{"name" => "Group 1"}},
            %{"id" => "group2", "profile" => %{"name" => "Group 2"}}
          ]

          conn
          |> Plug.Conn.put_resp_header(
            "link",
            "<http://test.okta.com/api/v1/groups?limit=200&after=cursor123>; rel=\"next\""
          )
          |> Req.Test.json(groups)
        end
      end)

      results =
        APIClient.stream_groups(client, "test_token")
        |> Enum.map(fn {:ok, group} -> group end)

      assert length(results) == 3
    end
  end

  describe "stream_users/2" do
    test "streams users successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        users = [
          %{"id" => "user1", "profile" => %{"email" => "user1@example.com"}},
          %{"id" => "user2", "profile" => %{"email" => "user2@example.com"}}
        ]

        Req.Test.json(conn, users)
      end)

      results =
        APIClient.stream_users(client, "test_token")
        |> Enum.map(fn {:ok, user} -> user end)

      assert length(results) == 2
      assert Enum.at(results, 0)["id"] == "user1"
    end
  end

  describe "stream_group_members/3" do
    test "streams group members successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        assert conn.request_path == "/api/v1/groups/group123/users"

        members = [
          %{"id" => "user1", "profile" => %{"email" => "member1@example.com"}},
          %{"id" => "user2", "profile" => %{"email" => "member2@example.com"}}
        ]

        Req.Test.json(conn, members)
      end)

      results =
        APIClient.stream_group_members("group123", client, "test_token")
        |> Enum.map(fn {:ok, member} -> member end)

      assert length(results) == 2
      assert Enum.at(results, 0)["id"] == "user1"
    end
  end

  describe "stream_apps/2" do
    test "streams apps successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        apps = [
          %{"id" => "app1", "label" => "Application 1"},
          %{"id" => "app2", "label" => "Application 2"}
        ]

        Req.Test.json(conn, apps)
      end)

      results =
        APIClient.stream_apps(client, "test_token")
        |> Enum.map(fn {:ok, app} -> app end)

      assert length(results) == 2
      assert Enum.at(results, 0)["id"] == "app1"
    end
  end

  describe "stream_app_groups/2" do
    test "streams app groups successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        assert conn.request_path == "/api/v1/apps/app123/groups"

        app_groups = [
          %{"id" => "ag1", "priority" => 1},
          %{"id" => "ag2", "priority" => 2}
        ]

        Req.Test.json(conn, app_groups)
      end)

      results =
        APIClient.stream_app_groups("app123", client, "test_token")
        |> Enum.map(fn {:ok, ag} -> ag end)

      assert length(results) == 2
      assert Enum.at(results, 0)["id"] == "ag1"
    end
  end

  describe "stream_app_users/2" do
    test "streams app users successfully", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        assert conn.request_path == "/api/v1/apps/app123/users"

        app_users = [
          %{"id" => "au1", "scope" => "USER"},
          %{"id" => "au2", "scope" => "GROUP"}
        ]

        Req.Test.json(conn, app_users)
      end)

      results =
        APIClient.stream_app_users("app123", client, "test_token")
        |> Enum.map(fn {:ok, au} -> au end)

      assert length(results) == 2
      assert Enum.at(results, 0)["id"] == "au1"
    end
  end

  describe "pagination" do
    test "handles authentication errors in stream", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 401, JSON.encode!(%{"error" => "unauthorized"}))
      end)

      results =
        APIClient.stream_groups(client, "test_token")
        |> Enum.to_list()

      assert [{:error, "Authentication Error"}] = results
    end

    test "handles server errors in stream", %{client: client} do
      Req.Test.stub(APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, JSON.encode!(%{"error" => "server_error"}))
      end)

      results =
        APIClient.stream_groups(client, "test_token")
        |> Enum.to_list()

      assert [{:error, reason}] = results
      assert reason =~ "Unexpected response with status 500"
    end
  end

  describe "retry behavior" do
    test "retries on 500 for GET requests and succeeds", %{client: client} do
      # Enable retry for this test
      Portal.Config.put_env_override(Portal.Okta.APIClient,
        req_opts: [
          plug: {Req.Test, Portal.Okta.APIClient},
          retry_delay: fn _n -> 1 end,
          max_retries: 1
        ]
      )

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(APIClient, fn conn ->
        call_count = Agent.get_and_update(agent, fn count -> {count, count + 1} end)

        case call_count do
          0 ->
            # First call fails with 500
            Plug.Conn.send_resp(conn, 500, JSON.encode!(%{"error" => "server_error"}))

          _ ->
            # Second call succeeds
            Req.Test.json(conn, [%{"id" => "group1", "name" => "Test Group"}])
        end
      end)

      results =
        APIClient.stream_groups(client, "test_token")
        |> Enum.to_list()

      assert [{:ok, %{"id" => "group1"}}] = results
      # Verify retry happened
      assert Agent.get(agent, & &1) == 2
    end

    test "retries on 429 rate limit with delay from headers", %{client: client} do
      # Enable retry for this test - no retry_delay since custom retry returns {:delay, ms}
      Portal.Config.put_env_override(Portal.Okta.APIClient,
        req_opts: [
          plug: {Req.Test, Portal.Okta.APIClient},
          max_retries: 1
        ]
      )

      {:ok, agent} = Agent.start_link(fn -> 0 end)
      # Set reset time to now so the delay is 0
      reset_time = System.system_time(:second)

      Req.Test.stub(APIClient, fn conn ->
        call_count = Agent.get_and_update(agent, fn count -> {count, count + 1} end)

        case call_count do
          0 ->
            # First call gets rate limited
            conn
            |> Plug.Conn.put_resp_header("x-rate-limit-reset", Integer.to_string(reset_time))
            |> Plug.Conn.send_resp(429, JSON.encode!(%{"error" => "rate_limit"}))

          _ ->
            # Second call succeeds
            Req.Test.json(conn, [%{"id" => "group1", "name" => "Test Group"}])
        end
      end)

      results =
        APIClient.stream_groups(client, "test_token")
        |> Enum.to_list()

      assert [{:ok, %{"id" => "group1"}}] = results
      # Verify retry happened
      assert Agent.get(agent, & &1) == 2
    end
  end
end
