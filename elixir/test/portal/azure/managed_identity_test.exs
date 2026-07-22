defmodule Portal.Azure.ManagedIdentityTest do
  use ExUnit.Case, async: true

  alias Portal.Azure.ManagedIdentity

  @database_resource "https://ossrdbms-aad.database.windows.net"

  # The GenServer is not started in the test environment (DATABASE_ENTRA_AUTH
  # is disabled), so database_access_token!/0 uses the direct-fetch fallback
  # unless a test starts the server itself.

  describe "database_access_token!/0 without the GenServer" do
    test "fetches a token for the managed identity from IMDS" do
      test_pid = self()

      Req.Test.expect(ManagedIdentity, fn conn ->
        send(test_pid, {:imds_request, conn})

        Req.Test.json(conn, %{
          "access_token" => "imds_token",
          "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
        })
      end)

      assert ManagedIdentity.database_access_token!() == "imds_token"

      assert_received {:imds_request, conn}
      assert conn.method == "GET"
      assert conn.request_path == "/metadata/identity/oauth2/token"
      assert Plug.Conn.get_req_header(conn, "metadata") == ["true"]

      params = URI.decode_query(conn.query_string)
      assert params["api-version"] == "2018-02-01"
      assert params["resource"] == "https://ossrdbms-aad.database.windows.net"
      assert params["client_id"] == "test-azure-client-id"
    end

    test "raises when IMDS returns an error" do
      Req.Test.expect(ManagedIdentity, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_request"})
      end)

      assert_raise MatchError, fn ->
        ManagedIdentity.database_access_token!()
      end
    end
  end

  describe "access token cache" do
    setup do
      server = start_supervised!({ManagedIdentity, name: unique_name()})

      # Establish stub ownership before allowing the server process to use it
      Req.Test.stub(ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      Req.Test.allow(ManagedIdentity, self(), server)
      %{server: server}
    end

    test "caches the token until it is about to expire", %{server: server} do
      Req.Test.expect(ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "cached_token",
          "expires_on" => System.system_time(:second) + 3600
        })
      end)

      assert access_token!(server, @database_resource) == "cached_token"
      # A second IMDS request would exceed the expectation above and raise
      assert access_token!(server, @database_resource) == "cached_token"
    end

    test "caches tokens independently by resource", %{server: server} do
      test_pid = self()

      Req.Test.expect(ManagedIdentity, 2, fn conn ->
        resource = URI.decode_query(conn.query_string)["resource"]
        send(test_pid, {:imds_request, resource})

        Req.Test.json(conn, %{
          "access_token" => "token-for-#{resource}",
          "expires_on" => System.system_time(:second) + 3600
        })
      end)

      assert access_token!(server, "resource-a") == "token-for-resource-a"
      assert access_token!(server, "resource-b") == "token-for-resource-b"
      assert access_token!(server, "resource-a") == "token-for-resource-a"
      assert access_token!(server, "resource-b") == "token-for-resource-b"

      assert_received {:imds_request, "resource-a"}
      assert_received {:imds_request, "resource-b"}
    end

    test "fetches a new token when the cached one is about to expire", %{server: server} do
      test_pid = self()

      Req.Test.expect(ManagedIdentity, 2, fn conn ->
        send(test_pid, :imds_request)

        Req.Test.json(conn, %{
          "access_token" => "short_lived_token",
          "expires_on" => System.system_time(:second) + 60
        })
      end)

      # The token expires within the refresh margin, so each call fetches
      assert access_token!(server, @database_resource) == "short_lived_token"
      assert access_token!(server, @database_resource) == "short_lived_token"

      assert_received :imds_request
      assert_received :imds_request
    end

    test "stays alive after a fetch error and recovers", %{server: server} do
      Req.Test.expect(ManagedIdentity, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server_error"})
      end)

      assert_raise MatchError, fn ->
        access_token!(server, @database_resource)
      end

      assert Process.alive?(server)

      Req.Test.expect(ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "recovered_token",
          "expires_on" => System.system_time(:second) + 3600
        })
      end)

      assert access_token!(server, @database_resource) == "recovered_token"
    end
  end

  describe "put_database_token/1" do
    test "replaces the connection password with a fresh token" do
      Req.Test.expect(ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "configure_token",
          "expires_on" => System.system_time(:second) + 3600
        })
      end)

      opts = ManagedIdentity.put_database_token(username: "apps-identity", password: "stale")

      assert opts[:password] == "configure_token"
      assert opts[:username] == "apps-identity"
    end
  end

  defp access_token!(server, resource) do
    case GenServer.call(server, {:access_token, resource}) do
      {:ok, token} -> token
      {:error, exception} -> raise exception
    end
  end

  defp unique_name, do: :"managed_identity_#{inspect(make_ref())}"
end
