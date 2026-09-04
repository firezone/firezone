defmodule PortalAPI.MCPControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.FeaturesFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  alias PortalAPI.MCP

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)

    %{account: account, actor: actor}
  end

  describe "transport" do
    test "rejects an unauthenticated request with a discovery challenge", %{conn: conn} do
      conn = rpc(conn, "server/discover")

      assert %{"status" => 401} = json_response(conn, 401)

      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(resource_metadata=")
      assert challenge =~ "/.well-known/oauth-protected-resource/mcp"

      # No scope is advertised, so a client with none configured asks for none
      # and the person picks on the consent screen.
      refute challenge =~ "scope="
    end

    test "rejects an API token, which is not a credential for this endpoint", %{
      conn: conn,
      account: account
    } do
      api_actor = actor_fixture(type: :api_client, account: account)
      conn = conn |> authorize_conn(api_actor) |> rpc("server/discover")

      assert json_response(conn, 401)
    end

    test "rejects a token minted for another audience", %{conn: conn, actor: actor} do
      {_token, encoded, _refresh} =
        Portal.OAuthFixtures.oauth_token_fixture(
          account: actor.account,
          actor: actor,
          resource: "https://mcp.evil.example.com/mcp"
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> encoded)
        |> rpc("server/discover")

      assert json_response(conn, 401)
    end

    test "rejects an expired token", %{conn: conn, actor: actor} do
      {_token, encoded, _refresh} =
        Portal.OAuthFixtures.oauth_token_fixture(
          account: actor.account,
          actor: actor,
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> encoded)
        |> rpc("server/discover")

      assert json_response(conn, 401)
    end

    test "answers GET with 405", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> get("/mcp")

      assert %{"error" => %{"code" => code}} = json_response(conn, 405)
      assert code == MCP.invalid_request()
    end

    test "answers DELETE with 405", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> delete("/mcp")

      assert json_response(conn, 405)
    end

    test "rejects a cross-origin request", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> put_req_header("origin", "https://evil.example.com")
        |> rpc("server/discover")

      assert %{"error" => %{"message" => message}} = json_response(conn, 403)
      assert message =~ "not allowed"
    end

    test "allows a same-origin request", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> put_req_header("origin", "http://www.example.com")
        |> rpc("server/discover")

      assert json_response(conn, 200)
    end

    test "returns 202 with no body for a notification", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/anything"}))

      assert response(conn, 202) == ""
    end

    test "rejects a body that is not JSON-RPC", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{"hello" => "world"}))

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == MCP.invalid_request()
    end

    test "returns 404 and -32601 for an unknown method", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> rpc("resources/list")

      assert %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 404)
      assert code == MCP.method_not_found()
      assert message =~ "resources/list"
    end
  end

  describe "header validation" do
    test "rejects a missing MCP-Protocol-Version header", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-method", "server/discover")
        |> post("/mcp", Jason.encode!(request("server/discover")))

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == MCP.header_mismatch()
    end

    test "rejects a header that disagrees with the body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> headers("server/discover")
        |> put_req_header("mcp-method", "tools/list")
        |> post("/mcp", Jason.encode!(request("server/discover")))

      assert %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 400)
      assert code == MCP.header_mismatch()
      assert message =~ "Mcp-Method"
    end

    test "rejects an unsupported protocol version", %{conn: conn, actor: actor} do
      body = request("server/discover") |> put_in(["params", "_meta", MCP.protocol_version_key()], "2024-11-05")

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> headers("server/discover")
        |> put_req_header("mcp-protocol-version", "2024-11-05")
        |> post("/mcp", Jason.encode!(body))

      assert %{"error" => %{"code" => code, "data" => data}} = json_response(conn, 400)
      assert code == MCP.unsupported_protocol_version()
      assert data == %{"supported" => MCP.supported_versions()}
    end

    test "rejects a request missing clientCapabilities", %{conn: conn, actor: actor} do
      body = request("server/discover") |> pop_in(["params", "_meta", MCP.client_capabilities_key()]) |> elem(1)

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> headers("server/discover")
        |> post("/mcp", Jason.encode!(body))

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == MCP.invalid_params()
    end

    test "decodes a base64 encoded Mcp-Name header", %{conn: conn, actor: actor} do
      encoded = "=?base64?" <> Base.encode64("list_resources") <> "?="

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> headers("tools/call")
        |> put_req_header("mcp-name", encoded)
        |> post("/mcp", Jason.encode!(request("tools/call", %{"name" => "list_resources"})))

      assert %{"result" => %{"isError" => false}} = json_response(conn, 200)
    end

    test "rejects an Mcp-Name that disagrees with the body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> headers("tools/call")
        |> put_req_header("mcp-name", "get_account")
        |> post("/mcp", Jason.encode!(request("tools/call", %{"name" => "list_resources"})))

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == MCP.header_mismatch()
    end
  end

  describe "server/discover" do
    test "reports versions, capabilities, and caching hints", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> rpc("server/discover")

      assert %{"result" => result} = json_response(conn, 200)

      assert result["resultType"] == "complete"
      assert result["supportedVersions"] == MCP.supported_versions()
      assert result["capabilities"] == %{"tools" => %{}}
      assert result["cacheScope"] == "public"
      assert result["ttlMs"] > 0
      assert result["instructions"] =~ "Firezone"
      assert %{"name" => "firezone"} = result["_meta"][MCP.server_info_key()]
    end
  end

  describe "tools/list" do
    test "lists only read tools when writes are disabled", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> rpc("tools/list")

      assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "list_resources" in names
      refute "create_resource" in names
      refute "delete_actor" in names

      assert Enum.all?(tools, & &1["annotations"]["readOnlyHint"])
    end

    test "lists a write tool only for the entities the scope covers", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_mcp_conn(actor, ~w[resources:write])
        |> rpc("tools/list")

      assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "create_resource" in names
      assert "list_resources" in names, "write implies read"
      refute "delete_actor" in names, "actors were never granted"
      refute "list_policies" in names, "policies were never granted"
    end

    test "returns tools in a stable order with cache hints", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> rpc("tools/list")

      assert %{"result" => result} = json_response(conn, 200)

      names = Enum.map(result["tools"], & &1["name"])
      assert names == Enum.sort(names)
      assert result["cacheScope"] == "private"
      assert result["ttlMs"] > 0
      refute Map.has_key?(result, "nextCursor")
    end

    test "every tool carries a name, description, and object input schema", %{
      conn: conn,
      actor: actor
    } do
      conn = conn |> authorize_mcp_conn(actor) |> rpc("tools/list")

      assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      for tool <- tools do
        assert is_binary(tool["name"])
        assert String.match?(tool["name"], ~r/^[a-z0-9_]+$/)
        assert is_binary(tool["description"]) and tool["description"] != ""
        assert %{"type" => "object", "properties" => _} = tool["inputSchema"]
      end
    end

    test "rejects a cursor it never issued", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> rpc("tools/list", %{"cursor" => "made-up"})

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == MCP.invalid_params()
    end
  end

  describe "tools/call" do
    test "runs a read tool and returns structured content", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> call_tool("list_resources", %{})

      assert %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == false
      assert %{"data" => [%{"id" => id}]} = result["structuredContent"]
      assert id == resource.id

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Jason.decode!(text) == result["structuredContent"]
    end

    test "passes path parameters through to the REST route", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> call_tool("get_resource", %{"id" => resource.id})

      assert %{"result" => %{"structuredContent" => %{"data" => data}}} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "passes query parameters through as filters", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site, name: "findable")
      _other = resource_fixture(account: account, site: site, name: "hidden")

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> call_tool("list_resources", %{"name" => "findable"})

      assert %{"result" => %{"structuredContent" => %{"data" => [found]}}} =
               json_response(conn, 200)

      assert found["id"] == resource.id
    end

    test "creates a record through a write tool", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      conn =
        conn
        |> authorize_mcp_conn(actor, ~w[policies:read policies:write resources:read resources:write])
        |> call_tool("create_resource", %{
          "resource" => %{
            "name" => "From MCP",
            "type" => "dns",
            "address" => "example.com",
            "site_id" => site.id
          }
        })

      assert %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == false
      assert result["structuredContent"]["data"]["name"] == "From MCP"
    end

    test "challenges for the write scope when the token lacks it", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> call_tool("delete_actor", %{"id" => actor.id})

      assert json_response(conn, 403)
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="actors:write")
      assert challenge =~ "oauth-protected-resource"
    end

    test "returns a protocol error for an unknown tool", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> call_tool("drop_database", %{})

      assert %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 400)
      assert code == MCP.invalid_params()
      assert message =~ "Unknown tool"
    end

    test "returns a tool error for an unknown argument", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> call_tool("list_resources", %{"nope" => "1"})

      assert %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "unknown argument"
    end

    test "returns a tool error for a path parameter that is not a scalar", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> call_tool("get_resource", %{"id" => %{"$ne" => nil}})

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "must be a string, number, or boolean: id"
    end

    test "returns a tool error for a missing path parameter", %{conn: conn, actor: actor} do
      conn = conn |> authorize_mcp_conn(actor) |> call_tool("get_resource", %{})

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "missing required argument"
    end

    test "surfaces an API error as a tool error, not a protocol error", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> call_tool("get_resource", %{"id" => Ecto.UUID.generate()})

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "could not be found"
    end

    test "scopes results to the caller's account", %{conn: conn, actor: actor} do
      other_account = account_fixture()
      other_site = site_fixture(account: other_account)
      other_resource = resource_fixture(account: other_account, site: other_site)

      conn =
        conn
        |> authorize_mcp_conn(actor)
        |> call_tool("get_resource", %{"id" => other_resource.id})

      assert %{"result" => %{"isError" => true}} = json_response(conn, 200)
    end

    test "writes one api_request_logs row naming the REST operation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      conn |> authorize_mcp_conn(actor) |> call_tool("list_resources", %{})

      logs = Portal.Repo.all(Portal.APIRequestLog)

      assert [log] = Enum.filter(logs, &(&1.account_id == account.id))
      assert log.method == "GET"
      assert log.path == "/resources"
    end
  end

  defp request(method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          MCP.protocol_version_key() => MCP.protocol_version(),
          MCP.client_capabilities_key() => %{}
        })
    }
  end

  defp headers(conn, method) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", MCP.protocol_version())
    |> put_req_header("mcp-method", method)
  end

  defp rpc(conn, method, params \\ %{}) do
    conn
    |> headers(method)
    |> post("/mcp", Jason.encode!(request(method, params)))
  end

  defp call_tool(conn, name, arguments) do
    conn
    |> headers("tools/call")
    |> put_req_header("mcp-name", name)
    |> post("/mcp", Jason.encode!(request("tools/call", %{"name" => name, "arguments" => arguments})))
  end
end
