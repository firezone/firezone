defmodule PortalWeb.OIDCControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import ExUnit.CaptureLog

  alias Portal.AuthenticationCache
  alias PortalWeb.Mocks

  setup do
    # Set up OIDC mock for all tests
    Mocks.OIDC.stub_discovery_document()
    :ok
  end

  describe "sign_in/2" do
    test "returns 404 when account not found", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, "/non-existent-account/sign_in/oidc/#{Ecto.UUID.generate()}")
      end
    end

    test "returns 404 when provider not found", %{conn: conn} do
      account = account_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        get(conn, "/#{account.id}/sign_in/oidc/#{Ecto.UUID.generate()}")
      end
    end

    test "returns 404 when provider is disabled", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account, is_disabled: true)

      assert_raise Ecto.NoResultsError, fn ->
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")
      end
    end

    test "redirects to IdP when account and provider are valid", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")
      state = auth_state_from_redirect(conn)

      assert redirected_to(conn) =~ "/authorize"
      assert {:ok, _auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
    end

    test "accepts account slug instead of id", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.slug}/sign_in/oidc/#{provider.id}")

      assert redirected_to(conn) =~ "/authorize"
    end

    test "stores OIDC auth state in AuthenticationCache with correct provider info", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")
      state = auth_state_from_redirect(conn)

      assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
      assert auth_state["auth_provider_type"] == "oidc"
      assert auth_state["auth_provider_id"] == provider.id
      assert auth_state["account_id"] == account.id
      assert auth_state["account_slug"] == account.slug
      assert is_binary(auth_state["session_binding"])
    end

    test "reuses existing oidc state binding from session", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)
      existing_binding = "existing-oidc-binding"

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:oidc_state_binding, existing_binding)
        |> get("/#{account.id}/sign_in/oidc/#{provider.id}")

      state = auth_state_from_redirect(conn)
      assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
      assert auth_state["session_binding"] == existing_binding
    end

    test "stores per-session binding and rejects callback replay from a different browser session",
         %{
           conn: conn
         } do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)
      actor = admin_actor_fixture(account: account, email: "admin@example.com")
      setup_successful_auth(%{account: account, provider: provider}, actor)

      attacker_conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")
      state = auth_state_from_redirect(attacker_conn)

      victim_conn =
        build_conn()
        |> get(~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert redirected_to(victim_conn) == "/"
      assert flash(victim_conn, :error) == "Your sign-in session has timed out. Please try again."
    end
  end

  describe "callback/2 with state and code (authentication)" do
    setup do
      account = account_fixture()
      provider = oidc_provider_fixture(account: account)

      {:ok, account: account, provider: provider}
    end

    test "redirects with error when OIDC state not found", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => "test-state", "code" => "test-code"})

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "redirects with error when cached auth state is missing session binding", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      state = Ecto.UUID.generate()

      :ok =
        AuthenticationCache.put(oidc_auth_cache_key(state), %{
          auth_provider_type: "oidc",
          auth_provider_id: provider.id,
          account_id: account.id,
          account_slug: account.slug,
          verifier: "test-verifier",
          params: %{}
        })

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "returns 404 when account in cookie no longer exists", %{conn: conn, provider: provider} do
      auth_state = %{
        auth_provider_type: "oidc",
        auth_provider_id: provider.id,
        account_id: Ecto.UUID.generate(),
        account_slug: "deleted-account",
        verifier: "test-verifier",
        params: %{}
      }

      assert_raise Ecto.NoResultsError, fn ->
        perform_callback(conn, auth_state, seed_via_sign_in: false)
      end
    end

    test "returns 404 when provider in cookie no longer exists", %{conn: conn, account: account} do
      auth_state = %{
        auth_provider_type: "oidc",
        auth_provider_id: Ecto.UUID.generate(),
        account_id: account.id,
        account_slug: account.slug,
        verifier: "test-verifier",
        params: %{}
      }

      assert_raise Ecto.NoResultsError, fn ->
        perform_callback(conn, auth_state, seed_via_sign_in: false)
      end
    end

    test "redirects with error when provider context doesn't allow portal access", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, context: :clients_only)
      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "This authentication method is not available for your sign-in context."
    end

    test "redirects with error when provider context doesn't allow client access", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, context: :portal_only)
      auth_state = build_oidc_auth_state(account, provider, params: %{"as" => "client"})
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) =~ "/#{account.slug}"

      assert flash(conn, :error) ==
               "This authentication method is not available for your sign-in context."
    end

    test "redirects with error when provider context doesn't allow headless-client access", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, context: :portal_only)

      auth_state =
        build_oidc_auth_state(account, provider, params: %{"as" => "headless-client"})

      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) =~ "/#{account.slug}"

      assert flash(conn, :error) ==
               "This authentication method is not available for your sign-in context."
    end

    test "allows headless-client access when provider context is clients_only", %{
      conn: conn,
      account: account
    } do
      %{provider: provider} = setup_oidc_provider(account, context: :clients_only)
      actor = admin_actor_fixture(account: account, email: "admin@example.com")

      ctx = %{conn: conn, account: account, provider: provider}
      setup_successful_auth(ctx, actor)

      auth_state =
        build_oidc_auth_state(account, provider, params: %{"as" => "headless-client"})

      conn = perform_callback(conn, auth_state)

      assert conn.status == 200
      assert conn.resp_body =~ "Copy token to clipboard"
    end
  end

  describe "callback/2 with Entra admin consent params" do
    test "redirects with error when state format is invalid", %{conn: conn} do
      params = %{
        "state" => "invalid-format",
        "admin_consent" => "True",
        "tenant" => "test-tenant-id"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Invalid sign-in request. Please try again."
    end

    test "redirects to verification for entra-verification state", %{conn: conn} do
      params = %{
        "state" => "entra-verification:test-token",
        "admin_consent" => "True",
        "tenant" => "test-tenant-id"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/verification"

      verification = get_session(conn, :verification)
      assert verification["type"] == "entra"
      assert verification["token"] == "test-token"
      assert {:ok, cached} = AuthenticationCache.get(verification_cache_key("test-token"))
      assert cached["entra_type"] == "auth_provider"
      assert cached["admin_consent"] == "True"
      assert cached["tenant_id"] == "test-tenant-id"
    end

    test "redirects to verification for entra-admin-consent state", %{conn: conn} do
      params = %{
        "state" => "entra-admin-consent:test-token",
        "admin_consent" => "True",
        "tenant" => "test-tenant-id"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/verification"

      verification = get_session(conn, :verification)
      assert verification["type"] == "entra"
      assert verification["token"] == "test-token"
      assert {:ok, cached} = AuthenticationCache.get(verification_cache_key("test-token"))
      assert cached["entra_type"] == "directory_sync"
    end

    test "passes through error params from Entra", %{conn: conn} do
      params = %{
        "state" => "entra-verification:test-token",
        "admin_consent" => "False",
        "tenant" => "test-tenant-id",
        "error" => "access_denied",
        "error_description" => "The user denied consent"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/verification"

      verification = get_session(conn, :verification)
      assert verification["token"] == "test-token"
      assert {:ok, cached} = AuthenticationCache.get(verification_cache_key("test-token"))
      assert cached["error"] == "access_denied"
      assert cached["error_description"] == "The user denied consent"
    end
  end

  describe "callback/2 with OIDC verification state" do
    test "redirects to verification page for oidc-verification state", %{conn: conn} do
      params = %{
        "state" => "oidc-verification:test-token",
        "code" => "authorization-code"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/verification"

      verification = get_session(conn, :verification)
      assert verification["type"] == "oidc"
      assert verification["token"] == "test-token"

      assert {:ok, cached} = AuthenticationCache.get(verification_cache_key("test-token"))
      assert cached["code"] == "authorization-code"
    end
  end

  describe "callback/2 (fallback with no recognized params)" do
    test "redirects with invalid callback params error when params don't match any pattern", %{
      conn: conn
    } do
      conn = get(conn, ~p"/auth/oidc/callback", %{"foo" => "bar"})

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Invalid sign-in request. Please try again."
    end

    test "redirects with invalid callback params error when no params", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback")

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Invalid sign-in request. Please try again."
    end
  end

  describe "callback routes do not redirect authenticated users" do
    setup do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      provider = oidc_provider_fixture(account: account)

      {:ok, account: account, actor: actor, provider: provider}
    end

    test "authenticated user can access /auth/oidc/callback without being redirected to portal",
         %{account: account, conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/auth/oidc/callback", %{"state" => "test-state", "code" => "test-code"})

      location = get_resp_header(conn, "location") |> List.first()
      refute location == ~p"/#{account.slug}/sites"
    end

    test "authenticated user can access legacy callback without being redirected to portal", %{
      conn: conn,
      actor: actor,
      account: account,
      provider: provider
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account.slug}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => "test-state",
          "code" => "test-code"
        })

      location = get_resp_header(conn, "location") |> List.first()
      refute location == ~p"/#{account.slug}/sites"
    end
  end

  describe "callback/2 token exchange errors" do
    setup do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider}
    end

    test "redirects with descriptive error when token exchange returns invalid_grant", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_grant"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "The authorization code has expired or was already used. Please try signing in again."
    end

    test "redirects with descriptive error when token exchange returns invalid_client", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_client"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Identity provider rejected the client credentials. Please verify your Client ID and Client Secret."
    end

    test "redirects with descriptive error when token exchange returns 401", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(401, %{"error" => "unauthorized"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Identity provider rejected the credentials. Please verify your Client ID and Client Secret are correct."
    end

    test "redirects with descriptive error when token exchange returns 500", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(500, %{"error" => "server_error"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Identity provider returned a server error (HTTP 500). Please try again later."
    end

    test "redirects with descriptive error when JWT verification fails", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "id_token" => "invalid-jwt-token",
        "token_type" => "Bearer"
      })

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) =~ "Failed to verify identity token:"
    end

    test "redirects with descriptive error when token endpoint is unreachable (transport error)",
         %{
           conn: conn,
           account: account,
           provider: provider
         } do
      # Replace stub with connection refused error
      Mocks.OIDC.stub_connection_refused()

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Unable to reach identity provider: Connection refused. The provider may be down or blocking requests."
    end

    test "redirects with descriptive error when token endpoint DNS lookup fails", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.stub_dns_error()

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Unable to reach identity provider: DNS lookup failed. Please verify the provider's domain is correct."
    end

    test "redirects with descriptive error when token endpoint times out", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Req.Test.stub(PortalWeb.OIDC, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Unable to reach identity provider: Connection timed out. Please try again."
    end

    test "redirects with descriptive error when token endpoint has unknown transport error", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Req.Test.stub(PortalWeb.OIDC, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Unable to reach identity provider: :closed. Please check your network connection and try again."
    end

    test "redirects with descriptive error when token endpoint returns invalid JSON", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      # Set up a stub that returns invalid JSON for token exchange
      # Use suffix matching to support dynamic per-test endpoints
      Req.Test.stub(PortalWeb.OIDC, fn conn ->
        conn = PortalWeb.Mocks.OIDC.__fetch_conn_params__(conn)

        cond do
          String.ends_with?(conn.request_path, "/.well-known/openid-configuration") ->
            Req.Test.json(conn, Mocks.OIDC.discovery_document())

          String.ends_with?(conn.request_path, "/.well-known/jwks.json") ->
            Req.Test.json(conn, %{"keys" => [Mocks.OIDC.jwks()]})

          String.ends_with?(conn.request_path, "/oauth/token") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, "not valid json")

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      auth_state = build_oidc_auth_state(account, provider)

      log =
        capture_log(fn ->
          conn = perform_callback(conn, auth_state)

          assert redirected_to(conn) == "/#{account.slug}"

          # JSON decode errors fall through to catch-all since they're unexpected
          assert flash(conn, :error) =~ "An unexpected error occurred"
        end)

      assert log =~ "OIDC sign-in error"
    end

    test "redirects with descriptive error when token exchange returns generic 400 error", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_request"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Identity provider returned an error: invalid_request. Please try again."
    end

    test "redirects with descriptive error when token exchange returns unhandled status", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(418, %{"error" => "teapot"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "Identity provider returned an error (HTTP 418). Please try again."
    end
  end

  describe "callback/2 successful authentication" do
    setup do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider}
    end

    test "successful portal sign-in for admin user creates session and redirects", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor)
      assert_portal_sign_in_success(ctx)
    end

    test "successful client sign-in for admin user creates token and renders redirect page",
         ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor)
      assert_client_sign_in_success(ctx)
    end

    test "successful client sign-in for regular user creates token and renders redirect page",
         ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")
      setup_successful_auth(ctx, actor, sub: "regular-user-123")
      assert_client_sign_in_success(ctx)
    end

    test "successful headless-client sign-in for admin user creates token and renders token page",
         ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor)
      assert_headless_client_sign_in_success(ctx)
    end

    test "successful headless-client sign-in for regular user creates token and renders token page",
         ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")
      setup_successful_auth(ctx, actor, sub: "regular-user-123")
      assert_headless_client_sign_in_success(ctx)
    end

    test "successful gui-client sign-in for admin user creates token and renders redirect page",
         ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor)
      assert_gui_client_sign_in_success(ctx)
    end

    test "successful sign-in with unverified email logs info message", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      setup_successful_auth(ctx, actor, email_verified: false)

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)

      log =
        capture_log(fn ->
          conn = perform_callback(ctx.conn, cookie)
          assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
        end)

      assert log =~ "OIDC identity email not verified"
    end

    test "successful sign-in derives name from given_name and family_name", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor, name: nil, given_name: "John", family_name: "Doe")
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in derives name from preferred_username", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      # Explicitly pass nil for name, given_name, family_name to ensure we hit preferred_username
      setup_successful_auth(ctx, actor,
        name: nil,
        given_name: nil,
        family_name: nil,
        preferred_username: "johndoe"
      )

      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in derives name from nickname", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      # Explicitly pass nil for name, given_name, family_name, preferred_username to ensure we hit nickname
      setup_successful_auth(ctx, actor,
        name: nil,
        given_name: nil,
        family_name: nil,
        preferred_username: nil,
        nickname: "johnny"
      )

      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in uses email as name when all name fields missing", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      # Explicitly pass nil for ALL name-related fields to ensure we hit the email fallback
      setup_successful_auth(ctx, actor,
        name: nil,
        given_name: nil,
        family_name: nil,
        preferred_username: nil,
        nickname: nil
      )

      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in treats non-string name values as missing", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      # Some IdPs might return unexpected types (integers, booleans, etc.)
      setup_successful_auth(ctx, actor,
        name: 12345,
        given_name: true,
        family_name: false,
        preferred_username: "validname"
      )

      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in treats empty string name as missing", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor, name: "", preferred_username: "johndoe")
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in treats whitespace-only name as missing", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor, name: "   ", nickname: "johnny")
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in treats empty given_name and family_name as missing", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor, name: nil, given_name: "", family_name: "")
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in with whitespace-only given_name uses family_name", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor, name: nil, given_name: "   ", family_name: "Doe")
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in with whitespace-only family_name uses given_name", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor, name: nil, given_name: "John", family_name: "   ")
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in with only given_name", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      # Explicitly pass family_name: nil to ensure {g, nil} branch is hit
      setup_successful_auth(ctx, actor, name: nil, given_name: "John", family_name: nil)
      assert_portal_sign_in_success(ctx)
    end

    test "successful sign-in with only family_name", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      # Explicitly pass given_name: nil to ensure {nil, f} branch is hit
      setup_successful_auth(ctx, actor, name: nil, given_name: nil, family_name: "Doe")
      assert_portal_sign_in_success(ctx)
    end

    test "redirects with error when non-admin user tries portal sign-in", ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")

      setup_successful_auth(ctx, actor, sub: "regular-user-123")

      auth_state = build_oidc_auth_state(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, auth_state)

      assert redirected_to(conn) == "/#{ctx.account.slug}"
      assert flash(conn, :error) == "This action requires admin privileges."
    end

    test "rejects client sign-in when users_limit_exceeded is true", ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")
      setup_successful_auth(ctx, actor, sub: "regular-user-123")

      update_account(ctx.account, %{users_limit_exceeded: true})

      auth_state =
        build_oidc_auth_state(ctx.account, ctx.provider, params: client_params())

      conn = perform_callback(ctx.conn, auth_state)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}"
      assert flash(conn, :error) =~ "exceeding billing limits"
    end

    test "allows gui-client sign-in when seats_limit_exceeded is true (soft limit)", ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")
      setup_successful_auth(ctx, actor, sub: "regular-user-123")

      update_account(ctx.account, %{seats_limit_exceeded: true})

      cookie =
        build_oidc_auth_state(ctx.account, ctx.provider,
          params: %{"as" => "gui-client", "nonce" => "client-nonce", "state" => "client-state"}
        )

      # Sign-in should still succeed since seats is a soft limit
      conn = perform_callback(ctx.conn, cookie)

      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "rejects headless-client sign-in when users_limit_exceeded is true", ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")
      setup_successful_auth(ctx, actor, sub: "regular-user-123")

      update_account(ctx.account, %{users_limit_exceeded: true})

      cookie =
        build_oidc_auth_state(ctx.account, ctx.provider,
          params: %{"as" => "headless-client", "state" => "client-state"}
        )

      conn = perform_callback(ctx.conn, cookie)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}"
      assert flash(conn, :error) =~ "exceeding billing limits"
    end

    test "allows client sign-in when only sites_limit_exceeded is true", ctx do
      actor = actor_fixture(account: ctx.account, email: "user@example.com")
      setup_successful_auth(ctx, actor, sub: "regular-user-123")

      # Sites limit doesn't block client sign-in
      update_account(ctx.account, %{sites_limit_exceeded: true})

      cookie = build_oidc_auth_state(ctx.account, ctx.provider, params: client_params())
      conn = perform_callback(ctx.conn, cookie)

      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "allows portal sign-in when users_limit_exceeded is true", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
      setup_successful_auth(ctx, actor)

      update_account(ctx.account, %{users_limit_exceeded: true})

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, cookie)

      # Portal sign-in should still be allowed so admins can manage billing
      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
    end
  end

  describe "callback/2 with userinfo fetch failure" do
    setup do
      # Disable Req retry for these tests to avoid multiple requests
      Application.put_env(:openid_connect, :retry, false)
      on_exit(fn -> Application.delete_env(:openid_connect, :retry) end)

      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider}
    end

    test "succeeds even when userinfo endpoint fails", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      id_token = sign_id_token(ctx.provider, actor)
      expect_token_exchange(id_token)

      # Userinfo endpoint returns error
      Mocks.OIDC.set_userinfo_error(500, %{"error" => "server_error"})

      assert_portal_sign_in_success(ctx)
    end
  end

  describe "callback/2 identity errors" do
    setup do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider}
    end

    test "redirects with error when no matching actor exists", ctx do
      # Sign token for a user that doesn't exist
      id_token =
        Mocks.OIDC.sign_openid_connect_token(%{
          "iss" => ctx.provider.issuer,
          "email" => "nonexistent@example.com",
          "sub" => "nonexistent-user-123",
          "name" => "Test User",
          "aud" => ctx.provider.client_id,
          "exp" => token_exp()
        })

      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "nonexistent-user-123",
        "email" => "nonexistent@example.com",
        "name" => "Test User"
      })

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, cookie)

      assert redirected_to(conn) == "/#{ctx.account.slug}"
      assert flash(conn, :error) == "Unable to sign you in. Please contact your administrator."
    end

    test "redirects with error when email claim is missing", ctx do
      # Some IdPs may not return an email claim
      id_token =
        Mocks.OIDC.sign_openid_connect_token(%{
          "iss" => ctx.provider.issuer,
          "sub" => "user-without-email-123",
          "name" => "User Without Email",
          "aud" => ctx.provider.client_id,
          "exp" => token_exp()
        })

      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "user-without-email-123",
        "name" => "User Without Email"
      })

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)

      log =
        capture_log(fn ->
          conn = perform_callback(ctx.conn, cookie)

          assert redirected_to(conn) == "/#{ctx.account.slug}"

          assert flash(conn, :error) ==
                   "Your identity provider returned invalid profile data. Please contact your administrator."
        end)

      assert log =~ "OIDC profile validation failed"
      assert log =~ "field=email"
    end

    # Test length validation for profile fields
    # Format: {field_name, claim_name, limit}
    for {field, claim, limit} <- [
          {"email", "email", 255},
          {"issuer", "iss", 2048},
          {"idp_id", "sub", 255},
          {"name", "name", 255},
          {"given_name", "given_name", 255},
          {"family_name", "family_name", 255},
          {"middle_name", "middle_name", 255},
          {"nickname", "nickname", 255},
          {"preferred_username", "preferred_username", 255},
          {"profile", "profile", 2048},
          {"picture", "picture", 2048}
        ] do
      @tag field: field, claim: claim, limit: limit
      test "redirects with error when #{field} exceeds #{limit} char limit", ctx do
        %{field: field, claim: claim, limit: limit} = ctx

        actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")
        long_value = String.duplicate("a", limit + 1)

        overrides = %{claim => long_value}

        id_token =
          Mocks.OIDC.sign_openid_connect_token(
            Map.merge(
              %{
                "iss" => ctx.provider.issuer,
                "email" => actor.email,
                "email_verified" => true,
                "sub" => "admin-user-123",
                "name" => actor.name,
                "aud" => ctx.provider.client_id,
                "exp" => token_exp()
              },
              overrides
            )
          )

        expect_token_exchange(id_token)

        Mocks.OIDC.set_userinfo_response(
          Map.merge(
            %{
              "sub" => "admin-user-123",
              "email" => actor.email,
              "email_verified" => true,
              "name" => actor.name
            },
            overrides
          )
        )

        cookie = build_oidc_auth_state(ctx.account, ctx.provider)

        log =
          capture_log(fn ->
            conn = perform_callback(ctx.conn, cookie)

            assert redirected_to(conn) == "/#{ctx.account.slug}"

            assert flash(conn, :error) ==
                     "Your identity provider returned invalid profile data. Please contact your administrator."
          end)

        assert log =~ "OIDC profile validation failed"
        assert log =~ "field=#{field}"
        assert log =~ "length=#{limit + 1}"
      end
    end
  end

  describe "sign_in/2 with Google provider" do
    test "redirects to IdP with prompt=select_account", %{conn: conn} do
      account = account_fixture()
      mock_endpoint = Mocks.OIDC.mock_endpoint()

      # Override Google config to use Req.Test mock
      Portal.Config.put_env_override(:portal, Portal.Google.AuthProvider,
        client_id: "test-google-client-id",
        client_secret: "test-google-client-secret",
        response_type: "code",
        scope: "openid email profile",
        discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
        req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
      )

      provider =
        google_provider_fixture(
          account: account,
          issuer: "#{mock_endpoint}/"
        )

      conn = get(conn, "/#{account.id}/sign_in/google/#{provider.id}")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "#{mock_endpoint}/authorize"
      assert redirect_url =~ "prompt=select_account"
    end
  end

  describe "sign_in/2 with Entra provider" do
    test "redirects to IdP with prompt=select_account", %{conn: conn} do
      account = account_fixture()
      mock_endpoint = Mocks.OIDC.mock_endpoint()

      # Override Entra config to use Req.Test mock
      Portal.Config.put_env_override(:portal, Portal.Entra.AuthProvider,
        client_id: "test-entra-client-id",
        client_secret: "test-entra-client-secret",
        response_type: "code",
        scope: "openid email profile",
        discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
        req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
      )

      provider =
        entra_provider_fixture(
          account: account,
          issuer: "#{mock_endpoint}/"
        )

      conn = get(conn, "/#{account.id}/sign_in/entra/#{provider.id}")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "#{mock_endpoint}/authorize"
      assert redirect_url =~ "prompt=select_account"
    end
  end

  describe "sign_in/2 with Okta provider" do
    test "redirects to IdP with prompt=select_account", %{conn: conn} do
      account = account_fixture()
      mock_endpoint = Mocks.OIDC.mock_endpoint()

      # Override Okta config to use Req.Test mock
      Portal.Config.put_env_override(:portal, Portal.Okta.AuthProvider,
        response_type: "code",
        scope: "openid email profile",
        discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
        req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
      )

      provider =
        okta_provider_fixture(
          account: account,
          okta_domain: "mock.oidc.test",
          issuer: "#{mock_endpoint}/"
        )

      conn = get(conn, "/#{account.id}/sign_in/okta/#{provider.id}")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "#{mock_endpoint}/authorize"
      assert redirect_url =~ "prompt=select_account"
    end
  end

  describe "callback/2 with unknown Entra state prefix" do
    test "redirects with error when state has unknown entra prefix", %{conn: conn} do
      params = %{
        "state" => "entra-unknown:test-token",
        "admin_consent" => "True",
        "tenant" => "test-tenant-id"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Invalid sign-in request. Please try again."
    end
  end

  describe "sign_in/2 with client context" do
    test "redirects to IdP with client params", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "client",
          "state" => "client-state",
          "nonce" => "client-nonce"
        })

      state = auth_state_from_redirect(conn)
      assert redirected_to(conn) =~ "/authorize"
      assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
      assert auth_state["params"]["as"] == "client"
    end

    test "preserves redirect_to param for client auth", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "client",
          "redirect_to" => "/some/path"
        })

      state = auth_state_from_redirect(conn)
      assert redirected_to(conn) =~ "/authorize"
      assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
      assert auth_state["params"]["redirect_to"] == "/some/path"
    end

    test "redirects to IdP with headless-client params", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "headless-client",
          "state" => "headless-state"
        })

      state = auth_state_from_redirect(conn)
      assert redirected_to(conn) =~ "/authorize"
      assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
      assert auth_state["params"]["as"] == "headless-client"
    end

    test "redirects to IdP with gui-client params", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "gui-client",
          "state" => "gui-state",
          "nonce" => "gui-nonce"
        })

      state = auth_state_from_redirect(conn)
      assert redirected_to(conn) =~ "/authorize"
      assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(state))
      assert auth_state["params"]["as"] == "gui-client"
    end
  end

  describe "sign_in/2 discovery document errors" do
    setup do
      # Disable Req retry for these tests to avoid timeouts
      Application.put_env(:openid_connect, :retry, false)

      # Clear the discovery document cache before each test in this block
      # so the library will attempt to fetch the document again
      OpenIDConnect.Document.Cache.clear()

      on_exit(fn ->
        Application.delete_env(:openid_connect, :retry)
      end)

      :ok
    end

    test "redirects with descriptive error when discovery document is unreachable (econnrefused)",
         %{
           conn: conn
         } do
      account = account_fixture()

      # Stub connection refused error for discovery document
      Mocks.OIDC.stub_connection_refused()
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Unable to fetch discovery document: Connection refused. The identity provider may be down."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document returns invalid JSON", %{
      conn: conn
    } do
      account = account_fixture()

      # Stub invalid JSON response for discovery document
      Mocks.OIDC.stub_invalid_json()
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) =~
                   "Discovery document contains invalid JSON"
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document returns 404", %{conn: conn} do
      account = account_fixture()

      # Stub 404 error for discovery document
      Mocks.OIDC.stub_discovery_error(404, "Not Found")
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Discovery document not found (HTTP 404). Please verify the Discovery Document URI is correct."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document returns 500", %{conn: conn} do
      account = account_fixture()

      # Stub 500 error for discovery document
      Mocks.OIDC.stub_discovery_error(500, "Internal Server Error")
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Identity provider returned a server error (HTTP 500). Please try again later."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document is unreachable (nxdomain)",
         %{conn: conn} do
      account = account_fixture()
      Mocks.OIDC.stub_dns_error()
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Unable to fetch discovery document: DNS lookup failed. Please verify the Discovery Document URI domain is correct."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with error when discovery document URI is a private IP", %{conn: conn} do
      account = account_fixture()

      # Bypass changeset validation to insert a provider with a private IP URI
      auth_provider = auth_provider_fixture(type: :oidc, account: account)
      unique_num = System.unique_integer([:positive, :monotonic])

      provider =
        %Portal.OIDC.AuthProvider{id: auth_provider.id}
        |> Ecto.Changeset.change(%{
          name: "Private IP OIDC #{unique_num}",
          context: :clients_and_portal,
          client_id: "test-client-#{unique_num}",
          client_secret: "test-secret-#{unique_num}",
          discovery_document_uri: "https://10.0.0.1/.well-known/openid-configuration",
          issuer: "https://auth.example.com",
          is_verified: true,
          is_disabled: false,
          client_session_lifetime_secs: 604_800,
          portal_session_lifetime_secs: 28_800
        })
        |> Ecto.Changeset.put_assoc(:auth_provider, auth_provider)
        |> Ecto.Changeset.put_assoc(:account, account)
        |> Portal.Repo.insert!()

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "The Discovery Document URI must not point to a private or reserved IP address."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document times out", %{conn: conn} do
      account = account_fixture()

      Mocks.OIDC.stub_discovery_document()

      Req.Test.stub(PortalWeb.OIDC, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Unable to fetch discovery document: Connection timed out. Please try again."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document returns non-404 4xx", %{
      conn: conn
    } do
      account = account_fixture()
      Mocks.OIDC.stub_discovery_error(418, "I'm a teapot")
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Failed to fetch discovery document (HTTP 418). Please verify your provider configuration."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document has unknown transport error",
         %{
           conn: conn
         } do
      account = account_fixture()

      Req.Test.stub(PortalWeb.OIDC, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"

          assert flash(conn, :error) ==
                   "Unable to fetch discovery document. Please check the Discovery Document URI."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error for unexpected discovery document shape", %{
      conn: conn
    } do
      account = account_fixture()

      Req.Test.stub(PortalWeb.OIDC, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{}")
      end)

      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

          assert redirected_to(conn) == "/#{account.slug}"
          assert flash(conn, :error) =~ "Unable to connect to the identity provider:"
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "preserves client params on transient discovery errors and succeeds on retry", %{
      conn: conn
    } do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      for params <- [
            %{
              "as" => "client",
              "state" => "client-state",
              "nonce" => "client-nonce",
              "redirect_to" => "/sites/site-1"
            },
            %{
              "as" => "gui-client",
              "state" => "gui-state",
              "nonce" => "gui-nonce"
            },
            %{
              "as" => "headless-client",
              "state" => "headless-state"
            }
          ] do
        OpenIDConnect.Document.Cache.clear()
        Mocks.OIDC.stub_connection_refused()

        failed_conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", params)
        failed_location = redirected_to(failed_conn)

        assert String.starts_with?(failed_location, "/#{account.slug}?")

        failed_query = failed_location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

        assert failed_query["as"] == params["as"]
        assert failed_query["state"] == params["state"]
        assert failed_query["nonce"] == params["nonce"]
        assert failed_query["redirect_to"] == params["redirect_to"]

        Mocks.OIDC.stub_discovery_document()

        retry_conn =
          get(
            recycle(conn),
            "/#{account.id}/sign_in/oidc/#{provider.id}",
            failed_query
          )

        retry_state = auth_state_from_redirect(retry_conn)

        assert redirected_to(retry_conn) =~ "/authorize"
        assert {:ok, auth_state} = AuthenticationCache.get(oidc_auth_cache_key(retry_state))
        assert auth_state["params"]["as"] == params["as"]
        assert auth_state["params"]["state"] == params["state"]
        assert auth_state["params"]["nonce"] == params["nonce"]
        assert auth_state["params"]["redirect_to"] == params["redirect_to"]
      end
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Sets up an OIDC provider with the Req.Test mock.
  defp setup_oidc_provider(account, opts \\ []) do
    provider = oidc_provider_fixture(:mock, Keyword.put(opts, :account, account))
    %{provider: provider}
  end

  # Builds OIDC auth state for AuthenticationCache-backed callbacks.
  defp build_oidc_auth_state(account, provider, opts \\ []) do
    %{
      auth_provider_type: "oidc",
      auth_provider_id: provider.id,
      account_id: account.id,
      account_slug: account.slug,
      verifier: Keyword.get(opts, :verifier, "test-verifier"),
      session_binding: Keyword.get(opts, :session_binding),
      params: Keyword.get(opts, :params, %{})
    }
  end

  # Performs OIDC callback by defaulting to the real sign_in flow to seed auth state.
  defp perform_callback(conn, auth_state, opts \\ []) do
    code = Keyword.get(opts, :code, "test-code")
    seed_via_sign_in? = Keyword.get(opts, :seed_via_sign_in, true)

    {conn, state} =
      if seed_via_sign_in? do
        conn =
          get(
            conn,
            "/#{auth_state.account_id}/sign_in/#{auth_state.auth_provider_type}/#{auth_state.auth_provider_id}",
            auth_state.params || %{}
          )

        state = Keyword.get(opts, :state, auth_state_from_redirect(conn))

        if is_binary(state) do
          {recycle(conn), state}
        else
          fallback_state = Ecto.UUID.generate()

          {conn, session_binding} = ensure_oidc_state_binding(conn)
          auth_state = Map.put(auth_state, :session_binding, session_binding)

          :ok = AuthenticationCache.put(oidc_auth_cache_key(fallback_state), auth_state)
          {recycle(conn), fallback_state}
        end
      else
        state = Keyword.get(opts, :state, Ecto.UUID.generate())
        {conn, session_binding} = ensure_oidc_state_binding(conn, opts)
        auth_state = Map.put(auth_state, :session_binding, session_binding)

        :ok = AuthenticationCache.put(oidc_auth_cache_key(state), auth_state)
        {conn, state}
      end

    conn
    |> get(~p"/auth/oidc/callback", %{"state" => state, "code" => code})
  end

  defp ensure_oidc_state_binding(conn, opts \\ []) do
    binding_override = Keyword.get(opts, :session_binding)

    cond do
      is_binary(binding_override) ->
        put_session_binding(conn, binding_override)

      is_binary(get_session(conn, :oidc_state_binding)) ->
        {conn, get_session(conn, :oidc_state_binding)}

      true ->
        put_session_binding(conn, Ecto.UUID.generate())
    end
  end

  defp put_session_binding(conn, binding) do
    conn =
      if conn.state in [:unset, :set] do
        conn
      else
        conn
        |> recycle()
        |> init_test_session(%{})
      end

    {put_session(conn, :oidc_state_binding, binding), binding}
  end

  defp verification_cache_key(token), do: AuthenticationCache.verification_key(token)
  defp oidc_auth_cache_key(state), do: AuthenticationCache.oidc_auth_key(state)

  defp auth_state_from_redirect(conn) do
    uri = redirected_to(conn) |> URI.parse()

    case uri.query do
      nil -> nil
      query -> query |> URI.decode_query() |> Map.get("state")
    end
  end

  # Sets up mocks for a successful authentication flow.
  defp setup_successful_auth(ctx, actor, opts \\ []) do
    id_token = sign_id_token(ctx.provider, actor, opts)
    expect_token_exchange(id_token)
    expect_userinfo(actor, opts)
  end

  # Signs a JWT id_token for testing.
  defp sign_id_token(provider, actor, opts \\ []) do
    sub = Keyword.get(opts, :sub, "admin-user-123")
    email_verified = Keyword.get(opts, :email_verified, true)

    claims =
      %{
        "iss" => provider.issuer,
        "email" => actor.email,
        "email_verified" => email_verified,
        "sub" => sub,
        "aud" => provider.client_id,
        "exp" => token_exp()
      }
      |> maybe_add_claim("name", opts, actor.name)
      |> maybe_add_claim("given_name", opts)
      |> maybe_add_claim("family_name", opts)
      |> maybe_add_claim("preferred_username", opts)
      |> maybe_add_claim("nickname", opts)

    Mocks.OIDC.sign_openid_connect_token(claims)
  end

  defp maybe_add_claim(claims, key, opts, default \\ nil) do
    case Keyword.fetch(opts, String.to_atom(key)) do
      # When explicitly passing nil, add the key with nil value so present(nil) is called
      {:ok, nil} -> Map.put(claims, key, nil)
      {:ok, value} -> Map.put(claims, key, value)
      :error when not is_nil(default) -> Map.put(claims, key, default)
      :error -> claims
    end
  end

  # Sets up the token exchange mock response.
  defp expect_token_exchange(id_token) do
    Mocks.OIDC.set_token_response(%{
      "access_token" => "test-access-token",
      "id_token" => id_token,
      "token_type" => "Bearer"
    })
  end

  # Sets up the userinfo endpoint mock response.
  defp expect_userinfo(actor, opts) do
    sub = Keyword.get(opts, :sub, "admin-user-123")
    email_verified = Keyword.get(opts, :email_verified, true)

    userinfo =
      %{
        "sub" => sub,
        "email" => actor.email,
        "email_verified" => email_verified
      }
      |> maybe_add_claim("name", opts, actor.name)
      |> maybe_add_claim("given_name", opts)
      |> maybe_add_claim("family_name", opts)
      |> maybe_add_claim("preferred_username", opts)
      |> maybe_add_claim("nickname", opts)

    Mocks.OIDC.set_userinfo_response(userinfo)
  end

  defp token_exp do
    DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()
  end

  defp client_params do
    %{"as" => "client", "nonce" => "client-nonce", "state" => "client-state"}
  end

  # Performs portal sign-in and asserts success.
  defp assert_portal_sign_in_success(ctx, opts \\ []) do
    auth_state = build_oidc_auth_state(ctx.account, ctx.provider, opts)
    conn = perform_callback(ctx.conn, auth_state)

    assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
    assert conn.resp_cookies["sess_#{ctx.account.id}"]

    conn
  end

  # Performs client sign-in and asserts success.
  defp assert_client_sign_in_success(ctx) do
    auth_state = build_oidc_auth_state(ctx.account, ctx.provider, params: client_params())
    conn = perform_callback(ctx.conn, auth_state)

    assert conn.status == 200
    assert conn.resp_body =~ "client_redirect"
    assert conn.resp_cookies["client_auth"]

    conn
  end

  # Performs gui-client sign-in and asserts success.
  defp assert_gui_client_sign_in_success(ctx) do
    auth_state =
      build_oidc_auth_state(ctx.account, ctx.provider,
        params: %{"as" => "gui-client", "nonce" => "client-nonce", "state" => "client-state"}
      )

    conn = perform_callback(ctx.conn, auth_state)

    assert conn.status == 200
    assert conn.resp_body =~ "client_redirect"
    assert conn.resp_cookies["client_auth"]

    conn
  end

  # Performs headless-client sign-in and asserts success.
  defp assert_headless_client_sign_in_success(ctx) do
    auth_state =
      build_oidc_auth_state(ctx.account, ctx.provider,
        params: %{"as" => "headless-client", "state" => "client-state"}
      )

    conn = perform_callback(ctx.conn, auth_state)

    assert conn.status == 200
    assert conn.resp_body =~ "Copy token to clipboard"
    # Headless client should NOT set client_auth cookie
    refute conn.resp_cookies["client_auth"]

    conn
  end
end
