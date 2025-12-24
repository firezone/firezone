defmodule PortalWeb.OIDCControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import ExUnit.CaptureLog

  alias PortalWeb.Cookie
  alias PortalWeb.Mocks

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
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

      assert redirected_to(conn) =~ "http://localhost:#{bypass.port}/authorize"
      assert get_resp_cookie(conn, "oidc")
    end

    test "accepts account slug instead of id", %{conn: conn} do
      account = account_fixture()
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.slug}/sign_in/oidc/#{provider.id}")

      assert redirected_to(conn) =~ "http://localhost:#{bypass.port}/authorize"
    end

    test "sets OIDC cookie with correct provider info", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")

      cookie = get_resp_cookie(conn, "oidc")
      assert cookie
      assert cookie.value
    end
  end

  describe "callback/2 with state and code (authentication)" do
    setup do
      account = account_fixture()
      provider = oidc_provider_fixture(account: account)

      {:ok, account: account, provider: provider}
    end

    test "redirects with error when OIDC cookie not found", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => "test-state", "code" => "test-code"})

      assert redirected_to(conn) == "/"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "redirects with error when state does not match", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      cookie = build_oidc_cookie(account, provider, state: "correct-state")

      conn = perform_callback(conn, cookie, state: "wrong-state")

      assert redirected_to(conn) == "/#{account.slug}"
      assert flash(conn, :error) == "Your sign-in session is invalid. Please try again."
    end

    test "returns 404 when account in cookie no longer exists", %{conn: conn, provider: provider} do
      cookie = %Cookie.OIDC{
        auth_provider_type: "oidc",
        auth_provider_id: provider.id,
        account_id: Ecto.UUID.generate(),
        account_slug: "deleted-account",
        state: "test-state",
        verifier: "test-verifier",
        params: %{}
      }

      assert_raise Ecto.NoResultsError, fn ->
        perform_callback(conn, cookie)
      end
    end

    test "returns 404 when provider in cookie no longer exists", %{conn: conn, account: account} do
      cookie = %Cookie.OIDC{
        auth_provider_type: "oidc",
        auth_provider_id: Ecto.UUID.generate(),
        account_id: account.id,
        account_slug: account.slug,
        state: "test-state",
        verifier: "test-verifier",
        params: %{}
      }

      assert_raise Ecto.NoResultsError, fn ->
        perform_callback(conn, cookie)
      end
    end

    test "redirects with error when provider context doesn't allow portal access", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, context: :clients_only)
      cookie = build_oidc_cookie(account, provider)

      conn = perform_callback(conn, cookie)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "This authentication method is not available for your sign-in context."
    end

    test "redirects with error when provider context doesn't allow client access", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account, context: :portal_only)
      cookie = build_oidc_cookie(account, provider, params: %{"as" => "client"})

      conn = perform_callback(conn, cookie)

      assert redirected_to(conn) =~ "/#{account.slug}"

      assert flash(conn, :error) ==
               "This authentication method is not available for your sign-in context."
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
      assert verification["entra_type"] == "auth_provider"
      assert verification["token"] == "test-token"
      assert verification["admin_consent"] == "True"
      assert verification["tenant_id"] == "test-tenant-id"
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
      assert verification["entra_type"] == "directory_sync"
      assert verification["token"] == "test-token"
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
      assert verification["error"] == "access_denied"
      assert verification["error_description"] == "The user denied consent"
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
      assert verification["code"] == "authorization-code"
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
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider, bypass: bypass}
    end

    test "redirects with error when token exchange fails", %{
      conn: conn,
      account: account,
      provider: provider,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        Plug.Conn.resp(conn, 400, JSON.encode!(%{"error" => "invalid_grant"}))
      end)

      cookie = build_oidc_cookie(account, provider)
      conn = perform_callback(conn, cookie)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "An unexpected error occurred while signing you in. Please try again."
    end

    test "redirects with error when token verification fails", %{
      conn: conn,
      account: account,
      provider: provider,
      bypass: bypass
    } do
      expect_token_exchange(bypass, "invalid-jwt-token")

      cookie = build_oidc_cookie(account, provider)
      conn = perform_callback(conn, cookie)

      assert redirected_to(conn) == "/#{account.slug}"

      assert flash(conn, :error) ==
               "An unexpected error occurred while signing you in. Please try again."
    end
  end

  describe "callback/2 successful authentication" do
    setup do
      account = account_fixture()
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider, bypass: bypass}
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

    test "successful sign-in with unverified email logs info message", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      setup_successful_auth(ctx, actor, email_verified: false)

      cookie = build_oidc_cookie(ctx.account, ctx.provider)

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

      cookie = build_oidc_cookie(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, cookie)

      assert redirected_to(conn) == "/#{ctx.account.slug}"
      assert flash(conn, :error) == "This action requires admin privileges."
    end
  end

  describe "callback/2 with userinfo fetch failure" do
    setup do
      account = account_fixture()
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider, bypass: bypass}
    end

    test "succeeds even when userinfo endpoint fails", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      id_token = sign_id_token(ctx.provider, actor)
      expect_token_exchange(ctx.bypass, id_token)

      # Userinfo endpoint returns error
      Bypass.expect_once(ctx.bypass, "GET", "/userinfo", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert_portal_sign_in_success(ctx)
    end
  end

  describe "callback/2 identity errors" do
    setup do
      account = account_fixture()
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider, bypass: bypass}
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

      expect_token_exchange(ctx.bypass, id_token)

      Mocks.OIDC.expect_userinfo(ctx.bypass, %{
        "sub" => "nonexistent-user-123",
        "email" => "nonexistent@example.com",
        "name" => "Test User"
      })

      cookie = build_oidc_cookie(ctx.account, ctx.provider)
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

      expect_token_exchange(ctx.bypass, id_token)

      Mocks.OIDC.expect_userinfo(ctx.bypass, %{
        "sub" => "user-without-email-123",
        "name" => "User Without Email"
      })

      cookie = build_oidc_cookie(ctx.account, ctx.provider)

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

        expect_token_exchange(ctx.bypass, id_token)

        Mocks.OIDC.expect_userinfo(
          ctx.bypass,
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

        cookie = build_oidc_cookie(ctx.account, ctx.provider)

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
      bypass = Mocks.OIDC.discovery_document_server()

      # Override Google config to use bypass
      Portal.Config.put_env_override(:domain, Portal.Google.AuthProvider,
        client_id: "test-google-client-id",
        client_secret: "test-google-client-secret",
        response_type: "code",
        scope: "openid email profile",
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

      provider = google_provider_fixture(bypass, account: account)

      conn = get(conn, "/#{account.id}/sign_in/google/#{provider.id}")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "http://localhost:#{bypass.port}/authorize"
      assert redirect_url =~ "prompt=select_account"
    end
  end

  describe "sign_in/2 with Entra provider" do
    test "redirects to IdP with prompt=select_account", %{conn: conn} do
      account = account_fixture()
      bypass = Mocks.OIDC.discovery_document_server()

      # Override Entra config to use bypass
      Portal.Config.put_env_override(:domain, Portal.Entra.AuthProvider,
        client_id: "test-entra-client-id",
        client_secret: "test-entra-client-secret",
        response_type: "code",
        scope: "openid email profile",
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

      provider = entra_provider_fixture(bypass, account: account)

      conn = get(conn, "/#{account.id}/sign_in/entra/#{provider.id}")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "http://localhost:#{bypass.port}/authorize"
      assert redirect_url =~ "prompt=select_account"
    end
  end

  describe "sign_in/2 with Okta provider" do
    test "redirects to IdP with prompt=select_account", %{conn: conn} do
      account = account_fixture()
      bypass = Mocks.OIDC.discovery_document_server()

      # Override Okta config to use bypass (HTTP instead of HTTPS)
      Portal.Config.put_env_override(:domain, Portal.Okta.AuthProvider,
        response_type: "code",
        scope: "openid email profile",
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

      provider = okta_provider_fixture(bypass, account: account)

      conn = get(conn, "/#{account.id}/sign_in/okta/#{provider.id}")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "http://localhost:#{bypass.port}/authorize"
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
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "client",
          "state" => "client-state",
          "nonce" => "client-nonce"
        })

      assert redirected_to(conn) =~ "http://localhost:#{bypass.port}/authorize"
      assert conn.resp_cookies["oidc"]
    end

    test "preserves redirect_to param for client auth", %{conn: conn} do
      account = account_fixture()
      %{bypass: bypass, provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "client",
          "redirect_to" => "/some/path"
        })

      assert redirected_to(conn) =~ "http://localhost:#{bypass.port}/authorize"
      assert conn.resp_cookies["oidc"]
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Sets up an OIDC provider with a mock discovery server.
  defp setup_oidc_provider(account, opts \\ []) do
    bypass = Mocks.OIDC.discovery_document_server()
    provider = oidc_provider_fixture(bypass, Keyword.put(opts, :account, account))

    %{bypass: bypass, provider: provider}
  end

  # Builds an OIDC cookie for testing callbacks.
  defp build_oidc_cookie(account, provider, opts \\ []) do
    %Cookie.OIDC{
      auth_provider_type: "oidc",
      auth_provider_id: provider.id,
      account_id: account.id,
      account_slug: account.slug,
      state: Keyword.get(opts, :state, "test-state"),
      verifier: Keyword.get(opts, :verifier, "test-verifier"),
      params: Keyword.get(opts, :params, %{})
    }
  end

  # Performs the OIDC callback request with cookie handling.
  defp perform_callback(conn, cookie, opts \\ []) do
    state = Keyword.get(opts, :state, "test-state")
    code = Keyword.get(opts, :code, "test-code")

    conn
    |> Cookie.OIDC.put(cookie)
    |> recycle_conn_with_cookie("oidc")
    |> get(~p"/auth/oidc/callback", %{"state" => state, "code" => code})
  end

  defp recycle_conn_with_cookie(conn, cookie_name) do
    cookie_value = conn.resp_cookies[cookie_name].value

    conn
    |> recycle()
    |> put_req_cookie(cookie_name, cookie_value)
  end

  # Sets up mocks for a successful authentication flow.
  defp setup_successful_auth(ctx, actor, opts \\ []) do
    id_token = sign_id_token(ctx.provider, actor, opts)
    expect_token_exchange(ctx.bypass, id_token)
    expect_userinfo(ctx.bypass, actor, opts)
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

  # Sets up the token exchange mock.
  defp expect_token_exchange(bypass, id_token) do
    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        JSON.encode!(%{
          "access_token" => "test-access-token",
          "id_token" => id_token,
          "token_type" => "Bearer"
        })
      )
    end)
  end

  # Sets up the userinfo endpoint mock.
  defp expect_userinfo(bypass, actor, opts) do
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

    Mocks.OIDC.expect_userinfo(bypass, userinfo)
  end

  defp token_exp do
    DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()
  end

  defp client_params do
    %{"as" => "client", "nonce" => "client-nonce", "state" => "client-state"}
  end

  defp get_resp_cookie(conn, name) do
    Map.get(conn.resp_cookies, name)
  end

  # Performs portal sign-in and asserts success.
  defp assert_portal_sign_in_success(ctx, opts \\ []) do
    cookie = build_oidc_cookie(ctx.account, ctx.provider, opts)
    conn = perform_callback(ctx.conn, cookie)

    assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
    assert conn.resp_cookies["sess_#{ctx.account.id}"]

    conn
  end

  # Performs client sign-in and asserts success.
  defp assert_client_sign_in_success(ctx) do
    cookie = build_oidc_cookie(ctx.account, ctx.provider, params: client_params())
    conn = perform_callback(ctx.conn, cookie)

    assert conn.status == 200
    assert conn.resp_body =~ "client_redirect"
    assert conn.resp_cookies["client_auth"]

    conn
  end
end
