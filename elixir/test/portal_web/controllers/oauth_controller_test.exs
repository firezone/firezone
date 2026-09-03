defmodule PortalWeb.OAuthControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OAuthFixtures

  alias Portal.OAuth

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
      assert metadata["scopes_supported"] == Portal.Scope.all()
    end

    test "is readable without a credential", %{conn: conn} do
      assert conn |> get(~p"/.well-known/oauth-authorization-server") |> json_response(200)
    end
  end

  describe "GET /oauth/authorize" do
    test "hands the parameters on intact when there is one recent account", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      params = authorize_params(client)

      cookie_conn =
        PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{
          account_ids: [account.id]
        })

      %{value: signed} = cookie_conn.resp_cookies["recent_accounts"]

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_cookie("recent_accounts", signed)
        |> get(~p"/oauth/authorize?#{params}")

      assert location = redirected_to(conn, 302)

      # Encoding the query here as well as in the route turned every = into
      # %3D and & into %26, so the far end saw one parameter and no client_id.
      forwarded = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert forwarded["client_id"] == client.client_id
      assert forwarded["code_challenge"] == params["code_challenge"]
      assert forwarded["state"] == "opaque-state"
    end

    test "submitting the account chooser carries the request on", %{
      conn: conn,
      account: account,
      client: client
    } do
      # The chooser is a form, and a form posts. Exercised here because reading
      # the page never proved the submit had anywhere to land.
      conn =
        post(conn, ~p"/oauth/authorize?#{authorize_params(client)}", %{
          "account_id_or_slug" => account.slug
        })

      assert location = redirected_to(conn, 302)
      assert %URI{path: path, query: query} = URI.parse(location)
      assert path == "/#{account.slug}/oauth/authorize"
      assert URI.decode_query(query)["client_id"] == client.client_id
    end

    test "a slug that matches no account says so instead of crashing", %{
      conn: conn,
      client: client
    } do
      conn =
        post(conn, ~p"/oauth/authorize?#{authorize_params(client)}", %{
          "account_id_or_slug" => "no-such-account"
        })

      response = html_response(conn, 200)

      assert response =~ "No account found"
      assert response =~ "account slug or ID"
    end

    test "a browser with no cookie is offered no account at all", %{
      conn: conn,
      account: account,
      client: client
    } do
      # The account exists in the database. Recent accounts come only from the
      # signed cookie, so a fresh browser must not be shown it, whether or not
      # it happens to be the only one there.
      response =
        conn
        |> get(~p"/oauth/authorize?#{authorize_params(client)}")
        |> html_response(200)

      refute response =~ account.name
      refute response =~ account.slug
      refute response =~ "Pick which Firezone account"
      refute response =~ "Recently signed in"
      assert response =~ "account slug or ID"
    end

    test "records the address the metadata document was served from", %{
      conn: conn,
      account: account
    } do
      client_id = "https://localhost/metadata.json"

      Req.Test.stub(Portal.OAuth.ClientMetadata, fn conn ->
        Req.Test.json(conn, %{
          "client_id" => client_id,
          "client_name" => "Local App",
          "redirect_uris" => [redirect_uri()]
        })
      end)

      params =
        %{client_id: client_id}
        |> authorize_params()
        |> Map.put("account_id_or_slug", account.slug)

      get(conn, ~p"/oauth/authorize?#{params}")

      client = Portal.Repo.get_by!(Portal.OAuthClient, client_id: client_id)
      assert %Postgrex.INET{address: {127, 0, 0, 1}} in client.resolved_ips
    end

    test "a client that does not check out is refused before anyone signs in", %{
      conn: conn,
      account: account
    } do
      params =
        %{client_id: "not-an-https-url"}
        |> authorize_params()
        |> Map.put("account_id_or_slug", account.slug)

      conn = get(conn, ~p"/oauth/authorize?#{params}")

      assert html_response(conn, 400) =~ "This request is not valid"
    end
  end

  describe "signing in mid-flow" do
    test "sign-in names the app being connected", %{
      conn: conn,
      account: account,
      client: client
    } do
      params = authorize_params(client)

      conn = get(conn, ~p"/#{account}/oauth/authorize?#{params}")
      sign_in_path = redirected_to(conn, 302)

      {:ok, _lv, html} = live(conn, sign_in_path)

      assert html =~ client.client_name
      assert html =~ "wants to connect to Firezone"
      assert html =~ URI.parse(client.client_id).host
    end

    test "the app is named the very first time a client connects", %{
      conn: conn,
      account: account
    } do
      # Nothing cached: the metadata document has never been fetched, which is
      # what a real first connection looks like and what the fixture hides.
      client_id = "https://brand-new.example.test/metadata.json"

      Req.Test.stub(Portal.OAuth.ClientMetadata, fn conn ->
        Req.Test.json(conn, %{
          "client_id" => client_id,
          "client_name" => "Brand New App",
          "redirect_uris" => [redirect_uri()]
        })
      end)

      params =
        %{client_id: client_id}
        |> authorize_params()
        |> Map.put("account_id_or_slug", account.slug)

      scoped = conn |> get(~p"/oauth/authorize?#{params}") |> redirected_to(302)
      sign_in_path = build_conn() |> get(scoped) |> redirected_to(302)

      html = build_conn() |> get(sign_in_path) |> html_response(200)

      assert html =~ "Brand New App"
      assert html =~ "wants to connect to Firezone"

      # and it keeps the centered look of the consent screen rather than
      # dropping into the marketing panel of a plain sign-in
      refute html =~ "Zero complexity"
    end

    test "sign-in says nothing when no connection is pending", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      refute html =~ "wants to connect to Firezone"
    end

    test "typing an account slug keeps the request rather than dropping it", %{
      conn: conn,
      account: account,
      client: client
    } do
      params = authorize_params(client) |> Map.put("account_id_or_slug", account.slug)

      conn = get(conn, ~p"/oauth/authorize?#{params}")

      assert location = redirected_to(conn, 302)
      assert %URI{path: path, query: query} = URI.parse(location)
      assert path == "/#{account.slug}/oauth/authorize"

      carried = URI.decode_query(query)
      assert carried["client_id"] == client.client_id
      assert carried["state"] == "opaque-state"
      refute Map.has_key?(carried, "account_id_or_slug")
    end

    test "an unauthenticated authorize keeps the whole request in redirect_to", %{
      conn: conn,
      account: account,
      client: client
    } do
      params = authorize_params(client)

      conn = get(conn, ~p"/#{account}/oauth/authorize?#{params}")

      assert location = redirected_to(conn, 302)
      assert %URI{path: path, query: query} = URI.parse(location)
      assert path == "/#{account.slug}/sign_in"

      # The OAuth request rides through sign-in as redirect_to, so nothing has
      # to be stashed in a cookie and the person lands back on consent.
      redirect_to = URI.decode_query(query)["redirect_to"]
      assert %URI{path: back_path, query: back_query} = URI.parse(redirect_to)
      assert back_path == "/#{account.slug}/oauth/authorize"

      carried = URI.decode_query(back_query)
      assert carried["client_id"] == client.client_id
      assert carried["code_challenge"] == params["code_challenge"]
      assert carried["state"] == "opaque-state"

      # and it is accepted on the way back
      assert PortalWeb.Session.Redirector.sanitize_redirect_to(account, redirect_to) ==
               redirect_to

      # Signing in is the first step of connecting, so nothing was denied and
      # there is no warning to show.
      refute flash(conn, :error)
    end
  end

  describe "GET /oauth/authorize with several recent accounts" do
    test "lists them to choose between", %{conn: conn, account: account, actor: actor, client: client} do
      other = Portal.AccountFixtures.account_fixture()
      params = authorize_params(client)

      cookie_conn =
        PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{
          account_ids: [account.id, other.id]
        })

      %{value: signed} = cookie_conn.resp_cookies["recent_accounts"]

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_cookie("recent_accounts", signed)
        |> get(~p"/oauth/authorize?#{params}")

      response = html_response(conn, 200)

      assert response =~ account.name
      assert response =~ other.name
      assert response =~ "Recently signed in"
      assert response =~ "/oauth/authorize?"
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

    test "a session for one account cannot consent on behalf of another", %{
      conn: conn,
      actor: actor,
      client: client
    } do
      other_account = Portal.AccountFixtures.account_fixture()

      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{other_account}/oauth/authorize?#{authorize_params(client)}")

      assert location = redirected_to(conn, 302)
      assert URI.parse(location).path == "/#{other_account.slug}/sign_in"
      assert Portal.Repo.all(Portal.OAuthGrant) == []
    end

    test "a portal session does not stand in for approving a connection", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      # Signed into the portal, and only into the portal. Approving an app is a
      # separate decision and has to be authenticated separately.
      signed_in = authorize_conn(conn, actor)
      {"cookie", cookies} = List.keyfind(signed_in.req_headers, "cookie", 0)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("cookie", cookies)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      assert location = redirected_to(conn, 302)
      assert %URI{path: path, query: query} = URI.parse(location)
      assert path == "/#{account.slug}/sign_in"
      assert URI.decode_query(query)["as"] == "oauth"
      assert Portal.Repo.all(Portal.OAuthGrant) == []
    end

    test "an approval session does not stand in for portal access", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/sites")

      assert location = redirected_to(conn, 302)
      assert URI.parse(location).path == "/#{account.slug}/sign_in"
    end

    test "shows the consent screen to a signed in actor", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      response = html_response(conn, 200)

      assert response =~ client.client_name

      # Every scope is offered as a checkbox; the ones the client asked for
      # start ticked and the rest are for the person to choose.
      assert response =~ ~s(name="scope[]")
      assert response =~ ~s(value="policies:read" checked)
      assert response =~ ~s(value="resources:write")
      refute response =~ ~s(value="resources:write" checked)
    end

    test "shows the client's icon when one was cached, inlined rather than hotlinked", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      png = <<137, 80, 78, 71, 13, 10, 26, 10>>

      client =
        oauth_client_fixture(logo_data: png, logo_content_type: "image/png")

      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      response = html_response(conn, 200)

      # a data: URI, so the page makes no request to the client and the content
      # security policy needs no exception
      assert response =~ "data:image/png;base64,#{Base.encode64(png)}"
      refute response =~ "<img src=\"https://"
    end

    test "falls back to the initial when no icon was cached", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      response = html_response(conn, 200)

      refute response =~ "data:image"
      assert response =~ String.upcase(String.first(client.client_name))
    end

    test "makes clear which app is connecting and where it came from", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      response = html_response(conn, 200)

      assert response =~ client.client_name

      # The origin the metadata document was fetched from is the part of the
      # identity that was actually checked, so it has to be on the page.
      host = URI.parse(client.client_id).host
      assert response =~ host

      # and the organization the permissions would apply to
      assert response =~ "should be able to access in the"
      assert response =~ account.name
      assert response =~ actor.name
    end

    test "the header leads with the address and where it was served from", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        oauth_client_fixture(
          resolved_ips: [%Postgrex.INET{address: {104, 18, 0, 1}}],
          resolved_ip_location_region: "US",
          resolved_ip_location_city: "San Francisco"
        )

      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{authorize_params(client)}")

      response = html_response(conn, 200)

      assert response =~ "104.18.0.1"
      assert response =~ "San Francisco, US"
      assert response =~ "Verified address"
      assert response =~ URI.parse(client.client_id).host

      # None of that is proof of anything, and the screen has to say so.
      assert response =~ "Only this address is checked"
    end

    test "names the write permission separately when it is asked for", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      params = %{authorize_params(client) | "scope" => "policies:write"}

      conn =
        conn
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{params}")

      response = html_response(conn, 200)

      assert response =~ ~s(value="policies:write" checked)
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
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{params}")

      assert html_response(conn, 200) =~ "not valid"
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
        |> authorize_oauth_conn(actor)
        |> get(~p"/#{account}/oauth/authorize?#{params}")

      assert location = redirected_to(conn, 302)
      assert %{"error" => "invalid_request", "state" => "opaque-state", "iss" => iss} =
               location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert iss == PortalWeb.Endpoint.url()
    end
  end

  describe "deciding on the consent screen" do
    test "a preset ticks boxes without granting anything", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      {:ok, lv, _html} = consent_screen(conn, account, actor, client, drop: "scope")

      html = lv |> element(~s(button[phx-value-preset="read"])) |> render_click()

      assert html =~ ~s(value="policies:read" checked)
      refute html =~ ~s(value="policies:write" checked)
      assert Portal.Repo.all(Portal.OAuthGrant) == []
    end

    test "approving with nothing ticked stays on the consent screen", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      {:ok, lv, _html} = consent_screen(conn, account, actor, client, drop: "scope")

      html = lv |> form("form") |> render_submit()

      assert html =~ "Select at least one permission to continue."
      assert Portal.Repo.all(Portal.OAuthGrant) == []
    end

    test "the person can grant a scope the client did not ask for", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      {:ok, lv, _html} = consent_screen(conn, account, actor, client)

      assert {:error, {:redirect, %{to: _location}}} =
               render_submit(lv, "allow", %{"scope" => ["resources:read"]})

      assert [grant] = Portal.Repo.all(Portal.OAuthGrant)
      assert grant.scopes == ["resources:read"]
    end

    test "approving returns a code to the client", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      {:ok, lv, _html} = consent_screen(conn, account, actor, client)

      assert {:error, {:redirect, %{to: location}}} =
               render_submit(lv, "allow", %{"scope" => ["policies:read"]})

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
      {:ok, lv, _html} = consent_screen(conn, account, actor, client)

      assert {:error, {:redirect, %{to: location}}} =
               lv |> element(~s(button[phx-click="deny"])) |> render_click()

      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["error"] == "access_denied"
      refute Map.has_key?(query, "code")
    end

    test "a scope that never existed is refused rather than granted", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      {:ok, lv, _html} = consent_screen(conn, account, actor, client)

      # The boxes are rendered by the server but posted back by the browser, so
      # what comes in is still checked against the vocabulary.
      assert {:error, {:redirect, %{to: location}}} =
               render_submit(lv, "allow", %{"scope" => ["policies:read", "admin:everything"]})

      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["error"] == "invalid_scope"
      assert Portal.Repo.all(Portal.OAuthGrant) == []
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
      assert body["scope"] == "policies:read"
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
      assert %Portal.Authentication.Credential.OAuthToken{} = subject.credential
      assert subject.credential.scopes == ["policies:read"]
      assert subject.credential.resource == OAuth.resource_uri()
    end

    test "a token minted for another audience is refused", %{account: account, actor: actor} do
      {_token, access, _refresh} =
        oauth_token_fixture(account: account, actor: actor, resource: "https://other.example/mcp")

      context = Portal.Authentication.Context.build({127, 0, 0, 1}, "testing", [], :mcp)

      assert {:error, :invalid_token} = Portal.Authentication.authenticate(access, context)
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

  describe "a native app redirect" do
    test "sends the code to the app's own scheme", %{conn: conn, account: account, actor: actor} do
      client = oauth_client_fixture(redirect_uris: ["com.example.app:/callback"])

      {:ok, lv, _html} =
        conn
        |> authorize_oauth_conn(actor)
        |> live(
          ~p"/#{account}/oauth/authorize?#{%{authorize_params(client) | "redirect_uri" => "com.example.app:/callback"}}"
        )

      {:error, {:redirect, %{to: location}}} =
        render_submit(lv, "allow", %{"scope" => ["policies:read"]})

      assert String.starts_with?(location, "com.example.app:/callback?")
      assert %{"code" => code} = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert is_binary(code)
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

  defp consent_screen(conn, account, actor, client, opts \\ []) do
    params =
      case Keyword.get(opts, :drop) do
        nil -> authorize_params(client)
        key -> Map.delete(authorize_params(client), key)
      end

    conn
    |> authorize_oauth_conn(actor)
    |> live(~p"/#{account}/oauth/authorize?#{params}")
  end

  defp approve(conn, account, actor, client) do
    {:ok, lv, _html} = consent_screen(conn, account, actor, client)

    {:error, {:redirect, %{to: location}}} =
      render_submit(lv, "allow", %{"scope" => ["policies:read"]})

    location
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
      "scope" => "policies:read",
      "resource" => OAuth.resource_uri(),
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false),
      "code_challenge_method" => "S256",
      "state" => "opaque-state"
    }
  end
end
