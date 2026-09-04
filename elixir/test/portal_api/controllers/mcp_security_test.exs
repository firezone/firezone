defmodule PortalAPI.MCPSecurityTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.FeaturesFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias PortalAPI.MCP
  alias PortalAPI.MCP.Tools

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    %{account: account, actor: actor}
  end

  test "invalid member IDs never delete any client tokens", %{conn: conn, account: account, actor: actor} do
    target = actor_fixture(account: account, type: :service_account)
    tokens = for _ <- 1..2, do: client_token_fixture(account: account, actor: target)
    conn = authorize_mcp_conn(conn, actor, ["client_tokens:write"])

    for id <- ["", nil, " ", "/", "..", "%2F", true, 1, [], %{}] do
      result = call_tool(conn, "delete_actor_client_token", %{"actor_id" => target.id, "id" => id})
      assert %{"result" => %{"isError" => true}} = json_response(result, 200)
      assert result.assigns.api_request_log.mcp["outcome"] == "rejected"
    end

    for token <- tokens do
      assert Repo.get_by(Portal.ClientToken, account_id: account.id, id: token.id)
    end

    [first, second] = tokens
    result = call_tool(conn, "delete_actor_client_token", %{"actor_id" => target.id, "id" => first.id})
    assert %{"result" => %{"isError" => false}} = json_response(result, 200)
    refute Repo.get_by(Portal.ClientToken, account_id: account.id, id: first.id)
    assert Repo.get_by(Portal.ClientToken, account_id: account.id, id: second.id)
  end

  test "empty gateway token ID cannot revoke a whole site", %{conn: conn, account: account, actor: actor} do
    site = site_fixture(account: account)
    tokens = for _ <- 1..2, do: gateway_token_fixture(account: account, site: site)
    result = conn |> authorize_mcp_conn(actor, ["gateway_tokens:write"]) |> call_tool("delete_site_gateway_token", %{"site_id" => site.id, "id" => ""})
    assert %{"result" => %{"isError" => true}} = json_response(result, 200)
    for token <- tokens, do: assert(Repo.get_by(Portal.GatewayToken, account_id: account.id, id: token.id))
  end

  test "dispatch refuses a tool bound to a different REST action", %{conn: conn, actor: actor} do
    conn = conn |> authorize_mcp_conn(actor) |> PortalAPI.Plugs.MCPAuth.call([])
    {:ok, tool} = Tools.fetch("get_resource")
    tool = %{tool | action: :delete}
    assert {:error, message} = MCP.Dispatch.call(tool, %{"id" => Ecto.UUID.generate()}, conn)
    assert message =~ "intended REST operation"
  end

  test "malformed params and metadata return invalid params, never exceptions", %{conn: conn, actor: actor} do
    conn = authorize_mcp_conn(conn, actor)
    for value <- [nil, false, 1, "bad", [], [%{}]], params <- [value, %{"_meta" => value}] do
      result = rpc(conn, "tools/list", params)
      assert %{"id" => 1, "error" => %{"code" => code}} = json_response(result, 400)
      assert code == MCP.invalid_params()
    end
  end

  test "the single MCP flag controls all tools", %{conn: conn, actor: actor} do
    enable_feature(:mcp)
    conn = authorize_mcp_conn(conn, actor, Portal.Scope.all())
    names = ["create_actor", "update_actor", "verify_client", "create_actor_client_token", "create_single_owner_gateway_token", "rotate_single_owner_gateway_token"]
    result = rpc(conn, "tools/list", with_meta(%{}))
    listed = json_response(result, 200)["result"]["tools"] |> Enum.map(& &1["name"])
    for name <- names, do: assert(name in listed)

    disable_feature(:mcp)
    assert rpc(conn, "tools/list", with_meta(%{})) |> response(404) == "Not Found"

    for name <- names do
      assert call_tool(conn, name, %{}) |> response(404) == "Not Found"
    end
  end

  test "identity management requires the OAuth write scope", %{conn: conn, actor: actor} do
    attrs = %{"name" => "Delegated admin", "type" => "account_admin_user", "email" => "delegated@example.com", "allow_email_otp_sign_in" => true}
    result = conn |> authorize_mcp_conn(actor, ["actors:read"]) |> call_tool("create_actor", %{"actor" => attrs})
    assert result.status == 403

    conn = authorize_mcp_conn(conn, actor, ["actors:write"])
    assert Enum.any?(Tools.list(["actors:write"]), &(&1.name == "create_actor"))
    result = call_tool(conn, "create_actor", %{"actor" => attrs})
    assert %{"result" => %{"isError" => false}} = json_response(result, 200)
    assert result.assigns.api_request_log.mcp["rest_status"] == 201

    disable_feature(:mcp)
    result = call_tool(conn, "create_actor", %{"actor" => attrs})
    assert response(result, 404) == "Not Found"
  end

  test "credential issuance does not log its secret", %{conn: conn, actor: actor, account: account} do
    target = actor_fixture(account: account, type: :service_account)
    args = %{"actor_id" => target.id, "client_token" => %{"expires_at" => DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601()}}
    result = conn |> authorize_mcp_conn(actor, ["client_tokens:write"]) |> call_tool("create_actor_client_token", args)
    assert %{"result" => %{"isError" => false}} = json_response(result, 200)
    metadata = result.assigns.api_request_log.mcp
    assert metadata["outcome"] == "succeeded"
    assert Enum.sort(Map.keys(metadata)) == ~w[http_status method outcome path rest_status tool_name]
  end

  test "audit distinguishes authorization failure and REST failure from success", %{conn: conn, actor: actor} do
    result = conn |> authorize_mcp_conn(actor, ["actors:read"]) |> call_tool("delete_actor", %{"id" => actor.id})
    assert result.status == 403
    assert result.assigns.api_request_log.path == "/mcp"
    assert result.assigns.api_request_log.mcp == %{"tool_name" => "delete_actor", "outcome" => "rejected", "http_status" => 403}

    result = conn |> authorize_mcp_conn(actor, ["resources:read"]) |> call_tool("get_resource", %{"id" => Ecto.UUID.generate()})
    assert result.status == 200
    assert result.assigns.api_request_log.mcp["outcome"] == "failed"
    assert result.assigns.api_request_log.mcp["rest_status"] == 404
  end

  defp call_tool(conn, name, arguments) do
    conn |> put_req_header("mcp-name", name) |> rpc("tools/call", with_meta(%{"name" => name, "arguments" => arguments}))
  end

  test "rejected headers and ignored notifications never claim REST dispatch", %{conn: conn, actor: actor} do
    conn = authorize_mcp_conn(conn, actor, ["actors:write"])
    params = with_meta(%{"name" => "delete_actor", "arguments" => %{"id" => actor.id}})
    rejected = conn |> put_req_header("mcp-name", "different_tool") |> rpc("tools/call", params)
    assert rejected.status == 400
    assert rejected.assigns.api_request_log.mcp["outcome"] == "rejected"
    refute Map.has_key?(rejected.assigns.api_request_log.mcp, "method")

    ignored = conn |> put_req_header("content-type", "application/json") |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "params" => params}))
    assert ignored.status == 202
    assert ignored.assigns.api_request_log.mcp == %{"outcome" => "ignored", "http_status" => 202}
  end

  test "an exception response cannot overwrite a persisted dispatch checkpoint", %{conn: conn, actor: actor} do
    conn = conn |> authorize_mcp_conn(actor) |> PortalAPI.Plugs.MCPAuth.call([]) |> put_resp_header("x-request-id", "test") |> PortalAPI.Plugs.RequestLog.call(mcp: true)
    PortalAPI.Plugs.MCPRequestLog.dispatched(conn, %{method: "DELETE", request_path: "/resources/#{Ecto.UUID.generate()}"})
    PortalAPI.Plugs.MCPRequestLog.finalize(%{conn | status: 500})
    log = Repo.get_by!(Portal.APIRequestLog, account_id: actor.account_id, log_id: conn.assigns.api_request_log.log_id)
    assert log.mcp["outcome"] == "dispatched"
  end

  defp with_meta(params) do
    Map.put(params, "_meta", %{MCP.protocol_version_key() => MCP.protocol_version(), MCP.client_capabilities_key() => %{}})
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-method", method)
    |> put_req_header("mcp-protocol-version", MCP.protocol_version())
    |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}))
  end
end
