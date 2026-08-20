defmodule PortalWeb.OAuthControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OAuthFixtures

  alias PortalAPI.MCP

  @verifier "a-code-verifier-long-enough-to-satisfy-the-pkce-rules"

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    client = oauth_client_fixture()

    %{account: account, actor: actor, client: client}
  end

  describe "authorization server metadata" do
    test "advertises the endpoints and the flow this server supports", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/oauth-authorization-server")

      assert metadata = json_response(conn, 200)

      assert metadata["issuer"] == PortalWeb.Endpoint.url()
      assert metadata["authorization_endpoint"] =~ "/oauth/authorize"
      assert metadata["token_endpoint"] =~ "/oauth/token"
      assert metadata["revocation_endpoint"] =~ "/oauth/revoke"
      assert metadata["code_challenge_methods_supported"] == ["S256"]
      assert metadata["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert metadata["token_endpoint_auth_methods_supported"] == ["none"]
      assert metadata["client_id_metadata_document_supported"] == true
      assert metadata["authorization_response_iss_parameter_supported"] == true
      assert metadata["scopes_supported"] == ["mcp:read", "mcp:write"]
    end

    test "is readable without a credential", %{conn: conn} do
      assert conn |> get(~p"/.well-known/oauth-authorization-server") |> json_response(200)
    end
  end

  describe "GET /:account/oauth/authorize" do
    test "sends an unauthenticated visitor through sign in and back", %{
      conn: conn,
      account: account,
      client: client
    } do
      conn = get(conn, ~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      assert location = redirected_to(conn, 302)
      assert location =~ "/sign_in"
      assert location =~ "redirect_to"
    end

    test "shows the consent screen to a signed in actor", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      response = html_response(conn, 200)

      assert response =~ client.client_name
      assert response =~ "See your configuration"
      refute response =~ "Change your configuration"
    end

    test "names the write permission separately when it is asked for", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      params = %{authorize_params(client) | "scope" => "mcp:write"}

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{params}")

      response = html_response(conn, 200)

      assert response =~ "See your configuration"
      assert response =~ "Change your configuration"
    end

    test "renders an error rather than redirecting when the client is unknown", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      params = %{
        "client_id" => "not-a-url",
        "redirect_uri" => "http://127.0.0.1:5173/callback",
        "response_type" => "code"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{params}")

      assert html_response(conn, 400) =~ "not valid"
    end

    test "redirects a bad request back to the client once the client is known", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      params = Map.delete(authorize_params(client), "code_challenge")

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{params}")

      assert location = redirected_to(conn, 302)
      assert %{"error" => "invalid_request", "state" => "opaque-state", "iss" => iss} =
               location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert iss == PortalWeb.Endpoint.url()
    end
  end

  describe "POST /:account/oauth/authorize" do
    test "approving returns a code to the client", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> post(
          ~p"/#{account}/oauth/authorize",
          Map.put(authorize_params(client), "decision", "allow")
        )

      assert location = redirected_to(conn, 302)
      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert is_binary(query["code"])
      assert query["state"] == "opaque-state"
      assert query["iss"] == PortalWeb.Endpoint.url()
      refute Map.has_key?(query, "error")
    end

    test "declining returns access_denied and no code", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> post(
          ~p"/#{account}/oauth/authorize",
          Map.put(authorize_params(client), "decision", "deny")
        )

      assert location = redirected_to(conn, 302)
      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["error"] == "access_denied"
      refute Map.has_key?(query, "code")
    end

    test "a tampered scope is re-checked rather than trusted", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      params =
        authorize_params(client)
        |> Map.put("decision", "allow")
        |> Map.put("scope", "mcp:read admin:everything")

      conn = conn |> authorize_conn(actor) |> post(~p"/#{account}/oauth/authorize", params)

      assert location = redirected_to(conn, 302)
      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["error"] == "invalid_scope"
    end
  end

  describe "POST /oauth/token" do
    test "exchanges a code for a token pair", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      code = approve(conn, account, actor, client)

      conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => @verifier,
          "client_id" => client.client_id,
          "redirect_uri" => redirect_uri()
        })

      assert body = json_response(conn, 200)

      assert body["token_type"] == "Bearer"
      assert body["scope"] == "mcp:read"
      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "the issued token works against the MCP endpoint", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      code = approve(conn, account, actor, client)

      body =
        build_conn()
        |> post(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => @verifier,
          "client_id" => client.client_id,
          "redirect_uri" => redirect_uri()
        })
        |> json_response(200)

      context =
        Portal.Authentication.Context.build({127, 0, 0, 1}, "testing", [], :mcp)

      assert {:ok, subject} =
               Portal.Authentication.authenticate(body["access_token"], context)

      assert subject.actor.id == actor.id
      assert subject.account.id == account.id
      assert subject.credential.type == :oauth_token
      assert subject.credential.scopes == ["mcp:read"]
      assert subject.credential.resource == MCP.resource_uri()
    end

    test "rejects an unsupported grant type", %{conn: conn} do
      conn = post(conn, ~p"/oauth/token", %{"grant_type" => "password"})

      assert %{"error" => "unsupported_grant_type"} = json_response(conn, 400)
    end

    test "rejects a wrong verifier", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      code = approve(conn, account, actor, client)

      conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => "wrong",
          "client_id" => client.client_id,
          "redirect_uri" => redirect_uri()
        })

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end
  end

  describe "POST /oauth/revoke" do
    test "always answers 200, whatever it is handed", %{conn: conn, account: account, actor: actor} do
      {_token, access, _refresh} = oauth_token_fixture(account: account, actor: actor)

      assert conn |> post(~p"/oauth/revoke", %{"token" => access}) |> response(200) == ""
      assert build_conn() |> post(~p"/oauth/revoke", %{"token" => "junk"}) |> response(200) == ""
      assert build_conn() |> post(~p"/oauth/revoke", %{}) |> response(200) == ""
    end
  end

  defp approve(conn, account, actor, client) do
    conn
    |> authorize_conn(actor)
    |> post(
      ~p"/#{account}/oauth/authorize",
      Map.put(authorize_params(client), "decision", "allow")
    )
    |> redirected_to(302)
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.fetch!("code")
  end

  defp authorize_params(client) do
    %{
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "scope" => "mcp:read",
      "resource" => MCP.resource_uri(),
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false),
      "code_challenge_method" => "S256",
      "state" => "opaque-state"
    }
  end
end
