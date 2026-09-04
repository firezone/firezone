defmodule PortalAPI.OAuthMetadataControllerTest do
  use PortalAPI.ConnCase, async: true

  alias PortalAPI.MCP

  test "publishes the protected resource metadata at the path scoped url", %{conn: conn} do
    conn = get(conn, "/.well-known/oauth-protected-resource/mcp")

    assert metadata = json_response(conn, 200)

    assert metadata["resource"] == MCP.resource_uri()
    assert metadata["authorization_servers"] == [MCP.authorization_server()]
    # Absent on purpose: a client with no scopes configured asks for whatever
    # this advertises, and everything would arrive pre-ticked on consent.
    refute Map.has_key?(metadata, "scopes_supported")
    assert metadata["bearer_methods_supported"] == ["header"]
  end

  test "publishes the same document at the root url", %{conn: conn} do
    root = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)
    scoped = build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

    assert root == scoped
  end

  test "is readable without a credential", %{conn: conn} do
    assert conn |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)
  end

  test "the challenge on 401 points at this document", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", "{}")

    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ MCP.resource_metadata_url()
  end
end
