defmodule PortalWeb.OIDCControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.IdentityFixtures
  import ExUnit.CaptureLog
  import Ecto.Query

  alias PortalWeb.Cookie
  alias PortalWeb.Mocks

  @request_context_headers ~w[
    user-agent
    x-geo-location-region
    x-geo-location-city
    x-geo-location-coordinates
    x-azure-geo-country
  ]

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

      assert redirected_to(conn) =~ "/authorize"
      assert oidc_cookie_from_response(conn) != nil
      assert_oidc_nonce_bound(conn)
    end

    test "requires a fresh IdP login for an OAuth approval", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}?as=oauth")

      params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["prompt"] == "login"
      assert oidc_cookie_from_response(conn).params["as"] == "oauth"
    end

    test "accepts account slug instead of id", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.slug}/sign_in/oidc/#{provider.id}")

      assert redirected_to(conn) =~ "/authorize"
    end

    test "stores OIDC auth state in cookie with correct provider info", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}")
      cookie = oidc_cookie_from_response(conn)

      assert cookie.auth_provider_type == "oidc"
      assert cookie.auth_provider_id == provider.id
      assert cookie.account_id == account.id
      assert cookie.account_slug == account.slug
      assert is_binary(cookie.state)
      assert is_binary(cookie.verifier)
    end

    test "rejects callback replay from a different browser (no oidc cookie)",
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

      assert redirected_to(victim_conn) == "/sign_in"
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

      assert redirected_to(conn) == "/sign_in"
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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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
      assert conn.resp_body =~ "Copy to clipboard"
    end
  end

  describe "callback/2 with Entra verification state" do
    @tenant_id "12345678-1234-1234-1234-123456789012"
    @tenant_issuer "https://login.microsoftonline.com/#{@tenant_id}/v2.0"
    @principal_id "87654321-4321-4321-4321-210987654321"

    test "derives the auth-provider tenant from a verified ID token", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      assert_tenant_proof_redirect(conn, "openid email profile", "none")

      set_entra_token_response("entra-client-id")
      conn = complete_entra_tenant_proof(conn)

      assert {:ok,
              %{
                ok: true,
                type: "entra-auth-provider",
                tenant_id: @tenant_id,
                issuer: @tenant_issuer,
                verification_ref: ^verification_ref
              }} = entra_verification_result_from_redirect(redirected_to(conn))
    end

    test "binds directory sync to a user identity from a verified ID token", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-sync-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-directory-sync", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      assert_tenant_proof_redirect(conn, "openid profile", "none")

      set_entra_token_response("entra-sync-client-id")
      conn = complete_entra_tenant_proof(conn)

      assert {:ok,
              %{
                ok: true,
                type: "entra-directory-sync",
                tenant_id: @tenant_id,
                principal_id: @principal_id,
                verification_ref: ^verification_ref
              }} = entra_verification_result_from_redirect(redirected_to(conn))
    end

    test "rejects a malformed directory-sync callback tenant", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-sync-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-directory-sync", verification_ref)

      conn =
        complete_entra_admin_consent(conn, state, %{
          "tenant" => "attacker-controlled-tenant"
        })

      assert {:ok, %{ok: false, error: error, verification_ref: ^verification_ref}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects a token for a tenant other than the admin-consent callback tenant", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)
      other_tenant_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

      conn = complete_entra_admin_consent(conn, state, %{"tenant" => other_tenant_id})
      assert URI.parse(redirected_to(conn)).path =~ other_tenant_id

      set_entra_token_response("entra-client-id")
      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects a malformed admin-consent callback tenant", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn =
        complete_entra_admin_consent(conn, state, %{
          "tenant" => "attacker-controlled-tenant"
        })

      assert {:ok, %{ok: false, error: error, verification_ref: ^verification_ref}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects a signed ID token whose issuer does not match tid", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)

      set_entra_token_response("entra-client-id", %{
        "iss" => "https://login.microsoftonline.com/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/v2.0"
      })

      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects a token signed by a key scoped to another tenant", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)

      Mocks.OIDC.set_jwks_response(
        Map.put(
          Mocks.OIDC.jwks(),
          "issuer",
          "https://login.microsoftonline.com/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/v2.0"
        )
      )

      set_entra_token_response("entra-client-id")

      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects a token whose nonce is not bound to the verification session", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)

      set_entra_token_response("entra-client-id", %{"nonce" => "wrong-nonce"})

      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects an Entra identity proof whose ID token audience is missing", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)

      "entra-client-id"
      |> entra_claims()
      |> Map.delete("aud")
      |> set_entra_claims_response()

      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects an Entra identity proof whose ID token audience does not match", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      set_entra_claims_response(entra_claims("other-client-id"))
      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "rejects an Entra identity proof whose ID token signature is invalid", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)

      id_token =
        "entra-client-id"
        |> entra_claims()
        |> Mocks.OIDC.sign_openid_connect_token()
        |> invalidate_jwt_signature()

      set_entra_id_token_response(id_token)
      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "does not exchange the authorization code when an Entra identity-proof callback is replayed",
         %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      consent_conn = complete_entra_admin_consent(conn, state)
      tenant_proof_state = callback_state_from_redirect(consent_conn)
      set_entra_token_response("entra-client-id")

      first_conn = complete_entra_tenant_proof(consent_conn)
      assert {:ok, %{ok: true}} = entra_verification_result_from_redirect(redirected_to(first_conn))
      flush_oidc_requests()

      replayed_conn =
        get(recycle(first_conn), ~p"/auth/oidc/callback", %{
          "state" => tenant_proof_state,
          "code" => "replayed-code"
        })

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(replayed_conn))

      assert error =~ "Verification session was not found or has expired"
      refute_received {:oidc_request, _path, _conn}
    end

    test "does not consume a newer pending verification when a stale Entra callback arrives", %{
      conn: conn
    } do
      stale_ref = Ecto.UUID.generate()
      current_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, current_ref)

      state = entra_tenant_proof_state(lv_pid, "entra-auth-provider", stale_ref)
      flush_oidc_requests()

      conn =
        get(recycle(conn), ~p"/auth/oidc/callback", %{
          "state" => state,
          "code" => "stale-code"
        })

      assert {:ok, %{ok: false, error: error, verification_ref: ^stale_ref}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Verification session was not found or has expired"
      refute_received {:oidc_request, _path, _conn}

      send(lv_pid, {:peek_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^current_ref}}
    end

    test "returns a signed failure when the admin denies consent", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn =
        get(conn, ~p"/auth/oidc/callback", %{
          "state" => state,
          "error" => "access_denied",
          "error_description" => "The user denied consent"
        })

      assert {:ok,
              %{
                ok: false,
                error: "The user denied consent",
                verification_ref: ^verification_ref
              }} = entra_verification_result_from_redirect(redirected_to(conn))
    end

    test "falls back to an interactive tenant proof when silent SSO is unavailable", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      silent_state = callback_state_from_redirect(conn)

      conn =
        get(recycle(conn), ~p"/auth/oidc/callback", %{
          "state" => silent_state,
          "error" => "interaction_required",
          "error_description" => "Silent SSO was unavailable"
        })

      assert_tenant_proof_redirect(conn, "openid email profile", nil)

      set_entra_token_response("entra-client-id")
      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: true, verification_ref: ^verification_ref}} =
               entra_verification_result_from_redirect(redirected_to(conn))
    end

    test "directory sync falls back to an interactive identity proof when OIDC consent is required",
         %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-sync-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-directory-sync", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      silent_state = callback_state_from_redirect(conn)

      conn =
        get(recycle(conn), ~p"/auth/oidc/callback", %{
          "state" => silent_state,
          "error" => "consent_required",
          "error_description" => "The user has not consented to sign in"
        })

      assert_tenant_proof_redirect(conn, "openid profile", nil)
    end

    test "rejects an Entra ID token without an immutable user object ID", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      set_entra_token_response("entra-client-id", %{"oid" => nil})
      conn = complete_entra_tenant_proof(conn)

      assert {:ok, %{ok: false, error: error}} =
               entra_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify the Microsoft Entra tenant"
    end

    test "returns a signed failure when the interactive tenant proof is denied", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      config = entra_verification_config("entra-client-id")
      lv_pid = pending_verification_process(config, verification_ref)
      state = entra_verification_state(lv_pid, "entra-auth-provider", verification_ref)

      conn = complete_entra_admin_consent(conn, state)
      silent_state = callback_state_from_redirect(conn)

      conn =
        get(recycle(conn), ~p"/auth/oidc/callback", %{
          "state" => silent_state,
          "error" => "interaction_required"
        })

      interactive_state = callback_state_from_redirect(conn)

      conn =
        get(recycle(conn), ~p"/auth/oidc/callback", %{
          "state" => interactive_state,
          "error" => "access_denied",
          "error_description" => "The user denied sign in"
        })

      assert {:ok,
              %{
                ok: false,
                error: "The user denied sign in",
                verification_ref: ^verification_ref
              }} = entra_verification_result_from_redirect(redirected_to(conn))
    end

    test "rejects an admin-consent response without signed state", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/oidc/callback", %{
          "state" => "attacker-controlled-state",
          "admin_consent" => "True",
          "tenant" => @tenant_id
        })

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Invalid sign-in request. Please try again."
    end
  end

  describe "callback/2 with OIDC verification state" do
    test "exchanges code and redirects to /verification/oidc with signed result on success", %{
      conn: conn
    } do
      id_token = Mocks.OIDC.sign_openid_connect_token(Mocks.OIDC.default_claims())

      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "token_type" => "Bearer",
        "id_token" => id_token
      })

      verification_ref = Ecto.UUID.generate()

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification,
                 %{
                   config: oidc_config(),
                   verifier: "test-verifier",
                   verification_ref: verification_ref
                 }}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="
      refute redirect_url =~ "code="

      assert {:ok, %{ok: true, verification_ref: ^verification_ref}} =
               oidc_verification_result_from_redirect(redirect_url)
    end

    test "redirects to /verification/oidc with failure result when code exchange fails", %{
      conn: conn
    } do
      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_grant"})

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification, %{config: oidc_config(), verifier: "test-verifier"}}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "bad-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert error =~ "authorization code has expired"
    end

    test "redirects to /verification/oidc with failure result when verified email is required and claim is false",
         %{
           conn: conn
         } do
      id_token =
        Mocks.OIDC.sign_openid_connect_token(
          Mocks.OIDC.default_claims()
          |> Map.put("email_verified", false)
        )

      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "token_type" => "Bearer",
        "id_token" => id_token
      })

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "353690423699814251281",
        "email" => "ada@example.com",
        "email_verified" => false
      })

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification,
                 %{
                   config: oidc_config(),
                   verifier: "test-verifier",
                   require_email_verified: true
                 }}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert error =~ "did not return email_verified=true"
    end

    test "accepts verified email from userinfo during OIDC verification", %{
      conn: conn
    } do
      id_token =
        Mocks.OIDC.sign_openid_connect_token(
          Mocks.OIDC.default_claims()
          |> Map.delete("email_verified")
        )

      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "token_type" => "Bearer",
        "id_token" => id_token
      })

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "353690423699814251281",
        "email" => "ada@example.com",
        "email_verified" => true
      })

      verification_ref = Ecto.UUID.generate()

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification,
                 %{
                   config: oidc_config(),
                   verifier: "test-verifier",
                   verification_ref: verification_ref,
                   require_email_verified: true
                 }}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: true, issuer: issuer, verification_ref: ^verification_ref}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert issuer == Mocks.OIDC.default_claims()["iss"]
    end

    test "rejects verified email from userinfo during OIDC verification when subject differs", %{
      conn: conn
    } do
      id_token =
        Mocks.OIDC.sign_openid_connect_token(
          Mocks.OIDC.default_claims()
          |> Map.delete("email_verified")
        )

      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "token_type" => "Bearer",
        "id_token" => id_token
      })

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "different-subject",
        "email" => "ada@example.com",
        "email_verified" => true
      })

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification,
                 %{
                   config: oidc_config(),
                   verifier: "test-verifier",
                   require_email_verified: true
                 }}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert error =~ "did not return email_verified=true"
    end

    test "returns userinfo fetch error when verified email is required and ID token omits claim",
         %{
           conn: conn
         } do
      id_token =
        Mocks.OIDC.sign_openid_connect_token(
          Mocks.OIDC.default_claims()
          |> Map.delete("email_verified")
        )

      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "token_type" => "Bearer",
        "id_token" => id_token
      })

      Mocks.OIDC.set_userinfo_error(500, %{"error" => "server_error"})

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification,
                 %{
                   config: oidc_config(),
                   verifier: "test-verifier",
                   require_email_verified: true
                 }}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert error == "Identity provider returned a server error (HTTP 500). Please try again later."
      refute error =~ "did not return email_verified=true"
    end

    test "returns unverified email error when ID token claim is false and userinfo fetch fails",
         %{
           conn: conn
         } do
      id_token =
        Mocks.OIDC.sign_openid_connect_token(
          Mocks.OIDC.default_claims()
          |> Map.put("email_verified", false)
        )

      Mocks.OIDC.set_token_response(%{
        "access_token" => "test-access-token",
        "token_type" => "Bearer",
        "id_token" => id_token
      })

      Mocks.OIDC.set_userinfo_error(500, %{"error" => "server_error"})

      lv_pid =
        spawn(fn ->
          receive do
            {:get_pending_verification, from} ->
              send(
                from,
                {:pending_verification,
                 %{
                   config: oidc_config(),
                   verifier: "test-verifier",
                   require_email_verified: true
                 }}
              )
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert error =~ "did not return email_verified=true"
      refute error =~ "server error"
    end

    test "redirects to /verification/oidc with failure result when LV does not respond", %{
      conn: conn
    } do
      # Use a dead PID — no process listening, so request_pending_verification times out
      dead_pid = spawn(fn -> :ok end)
      lv_pid_string = PortalWeb.OIDC.serialize_pid(dead_pid)
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "oidc-auth-provider")

      conn = get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "any-code"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "/verification/oidc?result="

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirect_url)

      assert error =~ "session was not found or has expired"
    end
  end

  describe "callback/2 with Google directory verification state" do
    setup do
      configure_google_directory_workload_identity()
      test_pid = self()

      Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
        send(test_pid, {:unexpected_google_managed_identity_request, conn.request_path})
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      Req.Test.stub(Portal.Google.APIClient, fn conn ->
        send(test_pid, {:unexpected_google_api_request, conn.request_path})
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "binds the authorized Workspace customer to the delegated service-account customer", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      set_google_directory_id_token(%{
        "email" => "workspace-admin@verified.example.com",
        "hd" => "verified.example.com"
      })

      expect_google_directory_admin_check(
        "workspace-admin@verified.example.com",
        {:ok,
         %{
          "id" => "C0123",
          "customerDomain" => "verified.example.com"
         }}
      )

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok,
              %{
                ok: true,
                type: "google-directory-sync",
                domain: "verified.example.com",
                verification_ref: ^verification_ref
              } = result} = oidc_verification_result_from_redirect(redirected_to(conn))

      refute Map.has_key?(result, :access_token)
      refute Map.has_key?(result, :customer_id)
    end

    test "rejects authorization from a different Workspace", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C-victim")
      state = google_directory_verification_state(lv_pid, verification_ref)

      set_google_directory_id_token(%{
        "email" => "attacker@attacker.example.com",
        "hd" => "attacker.example.com"
      })

      expect_google_directory_admin_check(
        "attacker@attacker.example.com",
        {:ok,
         %{
          "id" => "C-attacker",
          "customerDomain" => "attacker.example.com"
         }}
      )

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok,
              %{
                ok: false,
                type: "google-directory-sync",
                error: error,
                verification_ref: ^verification_ref
              }} = oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "different Workspace"
    end

    test "requires the authorizing user to have customer-read administrator permission", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      set_google_directory_id_token(%{
        "email" => "member@verified.example.com",
        "hd" => "verified.example.com"
      })

      expect_google_directory_admin_check(
        "member@verified.example.com",
        {:error, 403,
         %{"error" => %{"message" => "Not Authorized to access this resource/api"}}}
      )

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "must be a Workspace administrator"
      assert error =~ "permission to view customer information"
    end

    test "rejects a missing Google ID token before requesting delegated access", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      Mocks.OIDC.set_token_response(%{"access_token" => "unused-interactive-token"})

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "did not return an identity token"
      refute_received {:unexpected_google_managed_identity_request, _path}
      refute_received {:unexpected_google_api_request, _path}
    end

    test "rejects a Google ID token with an invalid signature before requesting delegated access", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      Mocks.OIDC.set_token_response(%{"id_token" => "not-a-signed-token"})

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify your identity token"
      refute_received {:unexpected_google_managed_identity_request, _path}
      refute_received {:unexpected_google_api_request, _path}
    end

    test "rejects a Google ID token for another OAuth client", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      set_google_directory_id_token(%{
        "aud" => "another-google-client",
        "hd" => "verified.example.com"
      })

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify your identity token"
      refute_received {:unexpected_google_managed_identity_request, _path}
      refute_received {:unexpected_google_api_request, _path}
    end

    test "rejects a Google ID token whose nonce is not bound to the verification", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      set_google_directory_id_token(%{
        "nonce" => "nonce-from-another-verification",
        "hd" => "verified.example.com"
      })

      conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Unable to verify your identity token"
      refute_received {:unexpected_google_managed_identity_request, _path}
      refute_received {:unexpected_google_api_request, _path}
    end

    test "requires a verified email from a managed Google Workspace account", %{conn: conn} do
      for {claims, expected_error} <- [
            {%{"email_verified" => false, "hd" => "verified.example.com"},
             "email is verified"},
            {%{"hd" => nil}, "managed Google Workspace account"},
            {%{"sub" => nil, "hd" => "verified.example.com"},
             "incomplete account identity information"}
          ] do
        verification_ref = Ecto.UUID.generate()
        lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
        state = google_directory_verification_state(lv_pid, verification_ref)
        set_google_directory_id_token(claims)

        callback_conn =
          get(recycle(conn), ~p"/auth/oidc/callback", %{
            "state" => state,
            "code" => "test-code"
          })

        assert {:ok, %{ok: false, error: error}} =
                 oidc_verification_result_from_redirect(redirected_to(callback_conn))

        assert error =~ expected_error
      end

      refute_received {:unexpected_google_managed_identity_request, _path}
      refute_received {:unexpected_google_api_request, _path}
    end

    test "does not exchange the authorization code when a Google verification callback is replayed",
         %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      set_google_directory_id_token(%{
        "email" => "workspace-admin@verified.example.com",
        "hd" => "verified.example.com"
      })

      expect_google_directory_admin_check(
        "workspace-admin@verified.example.com",
        {:ok,
         %{
          "id" => "C0123",
          "customerDomain" => "verified.example.com"
         }}
      )

      first_conn =
        get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "test-code"})

      assert {:ok, %{ok: true}} = oidc_verification_result_from_redirect(redirected_to(first_conn))
      flush_oidc_requests()

      replayed_conn =
        get(recycle(first_conn), ~p"/auth/oidc/callback", %{
          "state" => state,
          "code" => "replayed-code"
        })

      assert {:ok, %{ok: false, error: error}} =
               oidc_verification_result_from_redirect(redirected_to(replayed_conn))

      assert error =~ "Verification session was not found or has expired"
      refute_received {:oidc_request, _path, _conn}
    end

    test "does not consume a newer pending verification when a stale Google callback arrives", %{
      conn: conn
    } do
      stale_ref = Ecto.UUID.generate()
      current_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(current_ref, "C0123")
      state = google_directory_verification_state(lv_pid, stale_ref)
      flush_oidc_requests()

      conn =
        get(conn, ~p"/auth/oidc/callback", %{
          "state" => state,
          "code" => "stale-code"
        })

      assert {:ok, %{ok: false, error: error, verification_ref: ^stale_ref}} =
               oidc_verification_result_from_redirect(redirected_to(conn))

      assert error =~ "Verification session was not found or has expired"
      refute_received {:oidc_request, _path, _conn}

      send(lv_pid, {:peek_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^current_ref}}
    end

    test "returns a signed failure when Google authorization is denied", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()
      lv_pid = google_directory_pending_verification_process(verification_ref, "C0123")
      state = google_directory_verification_state(lv_pid, verification_ref)

      conn =
        get(conn, ~p"/auth/oidc/callback", %{
          "state" => state,
          "error" => "access_denied",
          "error_description" => "The administrator denied access"
        })

      assert {:ok,
              %{
                ok: false,
                error: "The administrator denied access",
                verification_ref: ^verification_ref
              }} = oidc_verification_result_from_redirect(redirected_to(conn))
    end
  end

  describe "callback/2 (fallback with no recognized params)" do
    test "redirects with invalid callback params error when params don't match any pattern", %{
      conn: conn
    } do
      conn = get(conn, ~p"/auth/oidc/callback", %{"foo" => "bar"})

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Invalid sign-in request. Please try again."
    end

    test "redirects with invalid callback params error when no params", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback")

      assert redirected_to(conn) == "/sign_in"
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
      refute location == ~p"/#{account}/sites"
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
        |> get(~p"/#{account}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => "test-state",
          "code" => "test-code"
        })

      location = get_resp_header(conn, "location") |> List.first()
      refute location == ~p"/#{account}/sites"
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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Unable to verify your identity token. Please try signing in again."
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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Unable to reach identity provider. Please check your network connection and try again."
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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Identity provider returned an error while signing you in. Please try again."
    end

    test "redirects with descriptive error when token exchange returns unhandled status", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(418, %{"error" => "teapot"})

      auth_state = build_oidc_auth_state(account, provider)
      conn = perform_callback(conn, auth_state)

      assert redirected_to(conn) == "/#{account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Identity provider returned an error (HTTP 418). Please try again."
    end

    test "redirects client sign-in errors to the dedicated client auth error page", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_grant"})

      auth_state = build_oidc_auth_state(account, provider, params: client_params())

      log =
        capture_log(fn ->
          conn = perform_callback(conn, auth_state)

          location = redirected_to(conn)
          assert String.starts_with?(location, "/#{account.slug}/sign_in/client_auth_error?")

          query =
            location
            |> URI.parse()
            |> Map.fetch!(:query)
            |> URI.decode_query()

          assert query["as"] == "client"
          assert query["state"] == "client-state"
          assert query["nonce"] == "client-nonce"

          assert query["error"] ==
                   "The authorization code has expired or was already used. Please try signing in again."
        end)

      assert log =~ "OIDC sign-in redirecting with error"
      assert log =~ "account_id=#{account.id}"

      assert log =~
               "The authorization code has expired or was already used. Please try signing in again."
    end
  end

  describe "callback/2 successful authentication" do
    setup do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      {:ok, account: account, provider: provider}
    end

    test "successful portal sign-in for admin user creates session and redirects", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor)
      assert_portal_sign_in_success(ctx)
    end

    test "rejects an ID token whose nonce is not bound to the sign-in session", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, nonce: "attacker-nonce")

      conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
      assert flash(conn, :error) == "Unable to verify your identity token. Please try signing in again."
    end

    test "recreated user with a new idp_id overwrites their identity in place", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      existing_identity =
        identity_fixture(
          account: ctx.account,
          actor: actor,
          issuer: ctx.provider.issuer,
          idp_id: "old-object-id",
          email: actor.email
        )

      # The user is deleted and recreated in the IdP: same verified email, brand
      # new object id. Sign-in must recycle the existing row instead of inserting
      # a second identity for the same actor.
      setup_successful_auth(ctx, actor, sub: "new-object-id", email: actor.email)

      conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"

      assert Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer,
               idp_id: "new-object-id"
             ).id == existing_identity.id

      refute Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer,
               idp_id: "old-object-id"
             )
    end

    test "rejects a second identity sharing the actor and issuer", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      directory = Portal.DirectoryFixtures.directory_fixture(account: ctx.account)

      # Interactive row keyed on the Entra `sub`, no directory association.
      identity_fixture(
        account: ctx.account,
        actor: actor,
        issuer: ctx.provider.issuer,
        idp_id: "entra-sub-#{System.unique_integer([:positive])}",
        email: actor.email
      )

      # A directory-synced row keyed on the Entra `oid` (GUID) used to be able to
      # coexist with the interactive row, leaving two identities for the same
      # actor and issuer. The unique index now forbids that second row outright.
      changeset =
        %Portal.ExternalIdentity{}
        |> Ecto.Changeset.cast(
          %{issuer: ctx.provider.issuer, idp_id: Ecto.UUID.generate(), email: actor.email},
          [:issuer, :idp_id, :email]
        )
        |> Ecto.Changeset.put_assoc(:account, ctx.account)
        |> Ecto.Changeset.put_assoc(:actor, actor)
        |> Ecto.Changeset.put_assoc(:directory, directory)
        |> Portal.ExternalIdentity.changeset()

      assert {:error, changeset} = Repo.insert(changeset)

      assert {"has already been taken", constraint} = changeset.errors[:base]
      assert constraint[:constraint] == :unique

      assert constraint[:constraint_name] ==
               "external_identities_account_id_actor_id_issuer_index"

      identity_count =
        Repo.aggregate(
          from(ei in Portal.ExternalIdentity,
            where: ei.account_id == ^ctx.account.id and ei.actor_id == ^actor.id
          ),
          :count
        )

      assert identity_count == 1
    end

    test "changed email with the same idp_id is matched by idp_id, not email", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "old-address@example.com")

      existing_identity =
        identity_fixture(
          account: ctx.account,
          actor: actor,
          issuer: ctx.provider.issuer,
          idp_id: "stable-subject",
          email: "old-address@example.com"
        )

      # Same subject, new email. The actor still carries the old email, so the
      # match must fall back to idp_id rather than create a second identity.
      setup_successful_auth(ctx, actor, sub: "stable-subject", email: "new-address@example.com")

      conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"

      identity =
        Repo.get_by!(Portal.ExternalIdentity,
          account_id: ctx.account.id,
          issuer: ctx.provider.issuer,
          idp_id: "stable-subject"
        )

      assert identity.id == existing_identity.id
      assert identity.email == "new-address@example.com"
    end

    test "sign-in does not overwrite an identity from a different issuer", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      other_issuer_identity =
        identity_fixture(
          account: ctx.account,
          actor: actor,
          issuer: "https://other-issuer.example",
          idp_id: "stable-subject",
          email: actor.email
        )

      # Same email and subject, but a different issuer. existing_identity is
      # scoped by issuer, so this must create a new identity and leave the
      # other issuer's identity untouched.
      setup_successful_auth(ctx, actor, sub: "stable-subject", email: actor.email)

      conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"

      assert new_identity =
               Repo.get_by(Portal.ExternalIdentity,
                 account_id: ctx.account.id,
                 issuer: ctx.provider.issuer,
                 idp_id: "stable-subject"
               )

      assert new_identity.id != other_issuer_identity.id

      assert Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: "https://other-issuer.example",
               idp_id: "stable-subject"
             ).id == other_issuer_identity.id
    end

    test "successful client sign-in for admin user creates token and renders redirect page",
         ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
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
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
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
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor)
      assert_gui_client_sign_in_success(ctx)
    end

    test "rejects sign-in with unverified email when verified email is required", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      setup_successful_auth(ctx, actor, email_verified: false)

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)

      log = capture_log(fn -> send(self(), {:conn, perform_callback(ctx.conn, cookie)}) end)
      assert_receive {:conn, conn}

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Your identity provider did not return email_verified=true for your account. Please verify your email with the identity provider or contact your administrator."

      refute log =~ "OIDC identity email not verified"
    end

    test "rejects sign-in when verified email is required and email_verified is missing", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      id_token =
        Mocks.OIDC.sign_openid_connect_token(%{
          "iss" => ctx.provider.issuer,
          "email" => actor.email,
          "sub" => "admin-user-123",
          "name" => actor.name,
          "aud" => ctx.provider.client_id,
          "exp" => token_exp(),
          "nonce" => PortalWeb.OIDC.nonce("test-verifier")
        })

      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "admin-user-123",
        "email" => actor.email,
        "name" => actor.name
      })

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, cookie)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Your identity provider did not return email_verified=true for your account. Please verify your email with the identity provider or contact your administrator."
    end

    test "accepts sign-in when verified email comes from matching userinfo", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      id_token = sign_id_token(ctx.provider, actor, email_verified: :omit)
      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "admin-user-123",
        "email" => actor.email,
        "email_verified" => true,
        "name" => actor.name
      })

      assert_portal_sign_in_success(ctx)
    end

    test "rejects sign-in when verified email userinfo subject differs", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      id_token = sign_id_token(ctx.provider, actor, email_verified: :omit)
      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "different-subject",
        "email" => actor.email,
        "email_verified" => true,
        "name" => actor.name
      })

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, cookie)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"

      assert flash(conn, :error) ==
               "Your identity provider did not return email_verified=true for your account. Please verify your email with the identity provider or contact your administrator."
    end

    test "successful sign-in with unverified email when verified email is not required", ctx do
      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :none
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      setup_successful_auth(ctx, actor, email_verified: false)

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)

      log = capture_log(fn -> send(self(), {:conn, perform_callback(ctx.conn, cookie)}) end)
      assert_receive {:conn, conn}

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      refute log =~ "OIDC identity email not verified"
    end

    test "successful sign-in matches actor email using citext semantics", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "Admin@Example.COM")

      setup_successful_auth(ctx, actor, email: "admin@example.com")

      assert_portal_sign_in_success(ctx)
    end

    test "proof email verification sends OTP and promotes pending identity after valid code", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: " Admin@Example.COM ")
      setup_successful_auth(ctx, actor, email_verified: false)

      cookie =
        build_oidc_auth_state(ctx.account, ctx.provider,
          params: %{"redirect_to" => "/#{ctx.account.slug}/actors"}
        )
      conn = perform_callback(ctx.conn, cookie)

      redirect_query = redirected_to(conn) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert redirected_to(conn) =~
               "/#{ctx.account.slug}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      refute redirected_to(conn) =~
               "/#{ctx.account.id}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      pending_cookie = pending_identity_cookie_from_response(conn)

      assert redirect_query["pending_identity_id"] == pending_cookie.pending_identity_id
      assert pending_cookie.params == %{"redirect_to" => "/#{ctx.account.slug}/actors"}

      assert %Portal.PendingIdentity{} = pending_identity =
               Repo.get_by(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)

      assert pending_identity.actor_id == actor.id
      assert pending_identity.auth_provider_id == ctx.provider.id

      refute Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer,
               idp_id: "admin-user-123"
             )

      assert_received {:email, email}
      assert email.to == [{"", actor.email}]
      refute email.text_body =~ "/verify?secret="
      assert email.text_body =~
               "/#{ctx.account.slug}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      refute email.text_body =~
               "/#{ctx.account.id}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      assert email.text_body =~ "pending_identity_id=#{pending_cookie.pending_identity_id}"
      assert email.text_body =~ "Location: Kyiv, UA"
      assert email.text_body =~ "IP address: 127.0.x.x"
      refute email.text_body =~ "127.0.0.1"
      refute email.text_body =~ "Coordinates"
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      conn =
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id,
          "redirect_to" => "/#{ctx.account.slug}/sites"
        })

      assert redirected_to(conn) == "/#{ctx.account.slug}/actors"
      assert conn.resp_cookies["sess_#{ctx.account.id}"]

      assert identity =
               Repo.get_by(Portal.ExternalIdentity,
                 account_id: ctx.account.id,
                 issuer: ctx.provider.issuer,
                 idp_id: "admin-user-123"
               )

      assert identity.actor_id == actor.id
      refute Repo.get_by(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)
      refute Repo.get_by(Portal.OneTimePasscode, id: pending_identity.one_time_passcode_id)
    end

    test "proof email verification recycles the actor's existing same-issuer identity", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      # The actor already holds an identity for this issuer under a previous
      # subject. Promoting the pending identity with the new subject must recycle
      # this row rather than insert a second one and trip the unique index.
      existing_identity =
        identity_fixture(
          account: ctx.account,
          actor: actor,
          issuer: ctx.provider.issuer,
          idp_id: "old-subject",
          email: actor.email
        )

      setup_successful_auth(ctx, actor, email_verified: false)

      cookie =
        build_oidc_auth_state(ctx.account, ctx.provider,
          params: %{"redirect_to" => "/#{ctx.account.slug}/actors"}
        )

      conn = perform_callback(ctx.conn, cookie)
      pending_cookie = pending_identity_cookie_from_response(conn)

      assert_received {:email, email}
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      conn =
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id,
          "redirect_to" => "/#{ctx.account.slug}/actors"
        })

      assert conn.resp_cookies["sess_#{ctx.account.id}"]

      identities =
        from(ei in Portal.ExternalIdentity,
          where: ei.account_id == ^ctx.account.id and ei.actor_id == ^actor.id
        )
        |> Repo.all()

      assert [identity] = identities
      assert identity.id == existing_identity.id
      assert identity.idp_id == "admin-user-123"
    end

    test "proof email verification uses original client params after valid code", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false, sub: "regular-user-123")

      auth_state =
        build_oidc_auth_state(ctx.account, ctx.provider,
          params: %{
            "as" => "gui-client",
            "state" => "original-client-state",
            "nonce" => "original-client-nonce"
          }
        )

      conn = perform_callback(ctx.conn, auth_state)
      pending_cookie = pending_identity_cookie_from_response(conn)

      assert pending_cookie.params == %{
               "as" => "gui-client",
               "state" => "original-client-state",
               "nonce" => "original-client-nonce"
             }

      assert_received {:email, email}
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      conn =
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id,
          "as" => "headless-client",
          "state" => "submitted-client-state",
          "nonce" => "submitted-client-nonce"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
      refute conn.resp_body =~ "Copy to clipboard"

      client_auth =
        conn
        |> recycle()
        |> with_endpoint_key_base()
        |> Cookie.ClientAuth.fetch()

      assert client_auth.state == "original-client-state"
    end

    test "proof email verification treats concurrent external identity insert as success", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      pending_cookie = pending_identity_cookie_from_response(conn)
      pending_identity = Repo.get_by!(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)
      assert_received {:email, email}
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      existing_identity =
        identity_fixture(
          account: ctx.account,
          actor: actor,
          issuer: ctx.provider.issuer,
          idp_id: "admin-user-123",
          email: actor.email,
          name: actor.name
        )

      conn =
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id
        })

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      assert conn.resp_cookies["sess_#{ctx.account.id}"]

      assert Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer,
               idp_id: "admin-user-123"
             ).id == existing_identity.id

      refute Repo.get_by(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)
      refute Repo.get_by(Portal.OneTimePasscode, id: pending_identity.one_time_passcode_id)
    end

    test "proof email verification does not relink an existing identity to a stale pending actor",
         ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor_a = admin_actor_fixture(account: ctx.account, email: unique_email())
      actor_b = admin_actor_fixture(account: ctx.account, email: unique_email())
      idp_id = "shared-idp-subject"

      setup_successful_auth(ctx, actor_a, email_verified: false, sub: idp_id)
      first_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      first_cookie = pending_identity_cookie_from_response(first_conn)
      assert_received {:email, first_email}
      [_, first_code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, first_email.text_body)

      setup_successful_auth(ctx, actor_b, email_verified: false, sub: idp_id)
      second_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      second_cookie = pending_identity_cookie_from_response(second_conn)
      assert_received {:email, second_email}
      [_, second_code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, second_email.text_body)

      conn =
        build_conn()
        |> with_endpoint_key_base()
        |> put_pending_identity_req_cookie(first_conn, first_cookie.pending_identity_id)
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => first_code,
          "pending_identity_id" => first_cookie.pending_identity_id
        })

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"

      assert identity =
               Repo.get_by(Portal.ExternalIdentity,
                 account_id: ctx.account.id,
                 issuer: ctx.provider.issuer,
                 idp_id: idp_id
               )

      assert identity.actor_id == actor_a.id
      assert identity.email == actor_a.email

      conn =
        build_conn()
        |> with_endpoint_key_base()
        |> put_pending_identity_req_cookie(second_conn, second_cookie.pending_identity_id)
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => second_code,
          "pending_identity_id" => second_cookie.pending_identity_id
        })

      assert redirected_to(conn) =~
               "/#{ctx.account.slug}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      assert flash(conn, :error) == "The verification code is invalid or expired."

      identity =
        Repo.get_by!(Portal.ExternalIdentity,
          account_id: ctx.account.id,
          issuer: ctx.provider.issuer,
          idp_id: idp_id
        )

      assert identity.actor_id == actor_a.id
      assert identity.email == actor_a.email
    end

    test "proof email verification preserves sign-in params after invalid code", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      auth_state =
        build_oidc_auth_state(ctx.account, ctx.provider,
          params: %{
            "as" => "gui-client",
            "state" => "client-state",
            "nonce" => "client-nonce",
            "redirect_to" => "/#{ctx.account.slug}/actors"
          }
        )

      conn = perform_callback(ctx.conn, auth_state)
      pending_cookie = pending_identity_cookie_from_response(conn)

      conn =
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => "wrong",
          "pending_identity_id" => pending_cookie.pending_identity_id,
          "as" => "headless-client",
          "state" => "submitted-state",
          "nonce" => "submitted-nonce",
          "redirect_to" => "/#{ctx.account.slug}/sites"
        })

      location = redirected_to(conn)
      assert location =~ "/#{ctx.account.slug}/sign_in/oidc/#{ctx.provider.id}/verify_identity"
      assert location =~ "as=gui-client"
      assert location =~ "state=client-state"
      assert location =~ "nonce=client-nonce"
      assert location =~ "redirect_to=%2F#{ctx.account.slug}%2Factors"
      assert location =~ "pending_identity_id=#{pending_cookie.pending_identity_id}"
      refute location =~ "headless-client"
      refute location =~ "submitted-state"
      refute location =~ "submitted-nonce"
      refute location =~ "sites"
      assert flash(conn, :error) == "The verification code is invalid or expired."
    end

    test "proof email verification deletes the passcode after too many invalid codes", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      pending_cookie = pending_identity_cookie_from_response(conn)
      pending_identity = Repo.get_by!(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)
      assert_received {:email, email}
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      for _ <- 1..Portal.OneTimePasscode.max_attempts() do
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => "wrong",
          "pending_identity_id" => pending_cookie.pending_identity_id
        })
      end

      # Budget exhausted: the passcode and its pending identity are deleted, so even
      # the correct code is now rejected and no identity is created.
      conn =
        conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id
        })

      assert flash(conn, :error) == "The verification code is invalid or expired."

      refute Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer
             )

      refute Repo.get_by(Portal.OneTimePasscode, id: pending_identity.one_time_passcode_id)
      refute Repo.get_by(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)
    end

    test "proof email verification requires the signed pending identity cookie", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      callback_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      pending_cookie = pending_identity_cookie_from_response(callback_conn)
      assert_received {:email, email}
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      conn =
        build_conn()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id
        })

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "verification with a non-existent provider redirects without raising", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      callback_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      pending_cookie = pending_identity_cookie_from_response(callback_conn)

      # A valid pending cookie but a provider that does not exist must not raise:
      # a raise would unwind past the constant-time padding. It redirects with a
      # generic error instead.
      conn =
        callback_conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{Ecto.UUID.generate()}/verify_identity", %{
          "secret" => "wrong",
          "pending_identity_id" => pending_cookie.pending_identity_id
        })

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "verification with a non-existent account redirects without raising", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      callback_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      pending_cookie = pending_identity_cookie_from_response(callback_conn)

      conn =
        callback_conn
        |> recycle()
        |> post(~p"/nonexistent-account/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => "wrong",
          "pending_identity_id" => pending_cookie.pending_identity_id
        })

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "proof email verification requires the pending identity provider", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      other_provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof,
          issuer: "https://other-idp.example.com"
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())
      setup_successful_auth(ctx, actor, email_verified: false)

      callback_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      pending_cookie = pending_identity_cookie_from_response(callback_conn)
      assert_received {:email, email}
      [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

      conn =
        callback_conn
        |> recycle()
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{other_provider.id}/verify_identity", %{
          "secret" => code,
          "pending_identity_id" => pending_cookie.pending_identity_id
        })

      assert redirected_to(conn) =~
               "/#{ctx.account.slug}/sign_in/oidc/#{other_provider.id}/verify_identity"

      assert flash(conn, :error) == "The verification code is invalid or expired."

      assert Repo.get_by(Portal.PendingIdentity, id: pending_cookie.pending_identity_id)

      refute Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer,
               idp_id: "admin-user-123"
             )
    end

    test "proof email verification binds each code to the pending identity link and cookie", ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      setup_successful_auth(ctx, actor, email_verified: false)
      first_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      first_cookie = pending_identity_cookie_from_response(first_conn)
      assert_received {:email, first_email}
      [_, first_code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, first_email.text_body)

      setup_successful_auth(ctx, actor, email_verified: false)
      second_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      second_cookie = pending_identity_cookie_from_response(second_conn)
      assert_received {:email, second_email}
      [_, _second_code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, second_email.text_body)

      conn =
        build_conn()
        |> with_endpoint_key_base()
        |> put_pending_identity_req_cookie(first_conn, first_cookie.pending_identity_id)
        |> put_pending_identity_req_cookie(second_conn, second_cookie.pending_identity_id)
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => first_code,
          "pending_identity_id" => second_cookie.pending_identity_id
        })

      assert redirected_to(conn) =~
               "/#{ctx.account.slug}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      assert flash(conn, :error) == "The verification code is invalid or expired."

      refute Repo.get_by(Portal.ExternalIdentity,
               account_id: ctx.account.id,
               issuer: ctx.provider.issuer,
               idp_id: "admin-user-123"
             )
    end

    test "proof email verification keeps multiple pending links valid and clears them all after success",
         ctx do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: unique_email())

      setup_successful_auth(ctx, actor, email_verified: false)
      first_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      first_cookie = pending_identity_cookie_from_response(first_conn)
      first_pending_identity = Repo.get_by!(Portal.PendingIdentity, id: first_cookie.pending_identity_id)
      assert_received {:email, first_email}
      [_, first_code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, first_email.text_body)

      setup_successful_auth(ctx, actor, email_verified: false)
      second_conn = perform_callback(ctx.conn, build_oidc_auth_state(ctx.account, ctx.provider))
      second_cookie = pending_identity_cookie_from_response(second_conn)
      second_pending_identity = Repo.get_by!(Portal.PendingIdentity, id: second_cookie.pending_identity_id)
      assert_received {:email, _second_email}

      conn =
        build_conn()
        |> with_endpoint_key_base()
        |> put_pending_identity_req_cookie(first_conn, first_cookie.pending_identity_id)
        |> put_pending_identity_req_cookie(second_conn, second_cookie.pending_identity_id)
        |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
          "secret" => first_code,
          "pending_identity_id" => first_cookie.pending_identity_id
        })

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      assert conn.resp_cookies["sess_#{ctx.account.id}"]

      assert conn.resp_cookies[pending_identity_cookie_key(first_cookie.pending_identity_id)].max_age == 0
      assert conn.resp_cookies[pending_identity_cookie_key(second_cookie.pending_identity_id)].max_age == 0

      refute Repo.get_by(Portal.PendingIdentity, id: first_cookie.pending_identity_id)
      refute Repo.get_by(Portal.PendingIdentity, id: second_cookie.pending_identity_id)
      refute Repo.get_by(Portal.OneTimePasscode, id: first_pending_identity.one_time_passcode_id)
      refute Repo.get_by(Portal.OneTimePasscode, id: second_pending_identity.one_time_passcode_id)
    end

    test "proof email verification skips OTP when external identity already exists", ctx do
      provider =
        oidc_provider_fixture(:mock,
          account: ctx.account,
          email_verification_method: :proof
        )

      ctx = %{ctx | provider: provider}
      actor = admin_actor_fixture(account: ctx.account, email: "admin@example.com")

      identity_fixture(
        account: ctx.account,
        actor: actor,
        issuer: ctx.provider.issuer,
        idp_id: "admin-user-123",
        email: actor.email,
        name: actor.name
      )

      setup_successful_auth(ctx, actor, email_verified: false)
      conn = assert_portal_sign_in_success(ctx)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      refute_received {:email, _email}
      refute conn.resp_cookies["pending_identity"]
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

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
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

    test "redirects with error when OIDC callback state does not match cookie state", ctx do
      auth_state = build_oidc_auth_state(ctx.account, ctx.provider)

      cookie = %Cookie.AuthenticationState{
        auth_provider_type: auth_state.auth_provider_type,
        auth_provider_id: auth_state.auth_provider_id,
        account_id: auth_state.account_id,
        account_slug: auth_state.account_slug,
        verifier: auth_state.verifier,
        params: auth_state.params,
        state: "original-state"
      }

      conn =
        ctx.conn
        |> with_endpoint_key_base()
        |> Cookie.AuthenticationState.put(cookie)
        |> recycle()
        |> get(~p"/auth/oidc/callback", %{"state" => "tampered-state", "code" => "test-code"})

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end

    test "redirects with error when OIDC cookie state is nil (verify_state catch-all)", ctx do
      cookie = %Cookie.AuthenticationState{
        auth_provider_type: "oidc",
        auth_provider_id: ctx.provider.id,
        account_id: ctx.account.id,
        account_slug: ctx.account.slug,
        verifier: "test-verifier",
        params: %{},
        state: nil
      }

      conn =
        ctx.conn
        |> with_endpoint_key_base()
        |> Cookie.AuthenticationState.put(cookie)
        |> recycle()
        |> get(~p"/auth/oidc/callback", %{"state" => "some-state", "code" => "test-code"})

      assert redirected_to(conn) == "/sign_in"
      assert flash(conn, :error) == "Your sign-in session has timed out. Please try again."
    end
  end

  describe "callback/2 with userinfo fetch failure" do
    setup do
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
          "email_verified" => true,
          "sub" => "nonexistent-user-123",
          "name" => "Test User",
          "aud" => ctx.provider.client_id,
          "exp" => token_exp(),
          "nonce" => PortalWeb.OIDC.nonce("test-verifier")
        })

      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "nonexistent-user-123",
        "email" => "nonexistent@example.com",
        "email_verified" => true,
        "name" => "Test User"
      })

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)
      conn = perform_callback(ctx.conn, cookie)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
      assert flash(conn, :error) == "Unable to sign you in. Please contact your administrator."
    end

    test "redirects with error when email claim is missing", ctx do
      # Some IdPs may not return an email claim
      id_token =
        Mocks.OIDC.sign_openid_connect_token(%{
          "iss" => ctx.provider.issuer,
          "email_verified" => true,
          "sub" => "user-without-email-123",
          "name" => "User Without Email",
          "aud" => ctx.provider.client_id,
          "exp" => token_exp(),
          "nonce" => PortalWeb.OIDC.nonce("test-verifier")
        })

      expect_token_exchange(id_token)

      Mocks.OIDC.set_userinfo_response(%{
        "sub" => "user-without-email-123",
        "email_verified" => true,
        "name" => "User Without Email"
      })

      cookie = build_oidc_auth_state(ctx.account, ctx.provider)

      log =
        capture_log(fn ->
          conn = perform_callback(ctx.conn, cookie)

          assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"

          assert flash(conn, :error) ==
                   "Your identity provider returned invalid profile data. Please contact your administrator."
        end)

      assert log =~ "OIDC profile validation failed"
      assert log =~ "field=email"
    end

    # Test length validation for profile fields
    # Format: {field_name, claim_name, limit}
    for {field, claim, limit} <- [
          {"email", "email", 160},
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

        long_value =
          if claim == "email" do
            suffix = "@example.com"
            String.duplicate("a", limit + 1 - String.length(suffix)) <> suffix
          else
            String.duplicate("a", limit + 1)
          end

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
                "exp" => token_exp(),
                "nonce" => PortalWeb.OIDC.nonce("test-verifier")
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

            assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"

            assert flash(conn, :error) ==
                     "Your identity provider returned invalid profile data. Please contact your administrator."
          end)

        assert log =~ "OIDC profile validation failed"
        assert log =~ "field=#{field}"
        assert log =~ "length=#{String.length(long_value)}"
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
      assert_oidc_nonce_bound(conn)
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
      assert_oidc_nonce_bound(conn)
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
      assert_oidc_nonce_bound(conn)
    end
  end

  describe "callback/2 with unknown Entra state" do
    test "redirects with error when state is unknown", %{conn: conn} do
      params = %{
        "state" => "entra-unknown",
        "admin_consent" => "True",
        "tenant" => "test-tenant-id"
      }

      conn = get(conn, ~p"/auth/oidc/callback", params)

      assert redirected_to(conn) == "/sign_in"
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

      assert redirected_to(conn) =~ "/authorize"
      cookie = oidc_cookie_from_response(conn)
      assert cookie.params["as"] == "client"
    end

    test "preserves redirect_to param for client auth", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "client",
          "redirect_to" => "/some/path"
        })

      assert redirected_to(conn) =~ "/authorize"
      cookie = oidc_cookie_from_response(conn)
      assert cookie.params["redirect_to"] == "/some/path"
    end

    test "redirects to IdP with headless-client params", %{conn: conn} do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account)

      conn =
        get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
          "as" => "headless-client",
          "state" => "headless-state"
        })

      assert redirected_to(conn) =~ "/authorize"
      cookie = oidc_cookie_from_response(conn)
      assert cookie.params["as"] == "headless-client"
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

      assert redirected_to(conn) =~ "/authorize"
      cookie = oidc_cookie_from_response(conn)
      assert cookie.params["as"] == "gui-client"
    end
  end

  describe "sign_in/2 discovery document errors" do
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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

          assert flash(conn, :error) ==
                   "Unable to fetch discovery document. Please check the Discovery Document URI."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "redirects with descriptive error when discovery document URI is structurally invalid",
         %{conn: conn} do
      account = account_fixture()
      auth_provider = auth_provider_fixture(type: :oidc, account: account)
      unique_num = System.unique_integer([:positive, :monotonic])

      provider =
        %Portal.OIDC.AuthProvider{id: auth_provider.id}
        |> Ecto.Changeset.change(%{
          name: "Invalid URI OIDC #{unique_num}",
          context: :clients_and_portal,
          client_id: "test-client-#{unique_num}",
          client_secret: "test-secret-#{unique_num}",
          discovery_document_uri: "not-a-valid-url",
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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

          assert flash(conn, :error) ==
                   "The Discovery Document URI is invalid. Please check your provider configuration."
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

          assert redirected_to(conn) == "/#{account.slug}/sign_in"

          assert flash(conn, :error) ==
                   "Unable to connect to the identity provider. Please try again or contact your administrator."
        end)

      assert log =~ "OIDC authorization URI error"
    end

    test "preserves client params on transient discovery errors and succeeds on retry", %{
      conn: conn
    } do
      account = account_fixture()
      %{provider: provider} = setup_oidc_provider(account, is_default: true)

      # This test needs to invalidate the discovery document between
      # iterations, so run against a private cache instance.
      cache = start_supervised!({OpenIDConnect.Document.Cache, name: :transient_retry_cache})
      Portal.Config.put_env_override(:portal, OpenIDConnect, document_cache: cache)

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
        # Evict the doc cached by the previous iteration's successful retry so
        # the connection-refused stub is actually consulted.
        OpenIDConnect.Document.Cache.clear()
        Mocks.OIDC.stub_connection_refused()

        failed_conn = get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", params)
        failed_location = redirected_to(failed_conn)

        assert String.starts_with?(failed_location, "/#{account.slug}/sign_in/client_auth_error?")

        failed_query = failed_location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

        assert failed_query["as"] == params["as"]
        assert failed_query["state"] == params["state"]
        assert failed_query["nonce"] == params["nonce"]
        assert failed_query["redirect_to"] == params["redirect_to"]
        assert failed_query["error"] =~ "Unable to fetch discovery document"

        Mocks.OIDC.stub_discovery_document()

        retry_params = Map.drop(failed_query, ["error"])

        retry_conn =
          get(
            recycle(conn),
            "/#{account.slug}/sign_in",
            retry_params
          )

        provider_retry_path = redirected_to(retry_conn)
        assert provider_retry_path =~ "/sign_in/oidc/#{provider.id}"

        provider_conn =
          get(
            recycle(conn),
            provider_retry_path
          )

        assert redirected_to(provider_conn) =~ "/authorize"
        cookie = oidc_cookie_from_response(provider_conn)
        assert cookie.params["as"] == params["as"]
        assert cookie.params["state"] == params["state"]
        assert cookie.params["nonce"] == params["nonce"]
        assert cookie.params["redirect_to"] == params["redirect_to"]
      end
    end

    test "redirects client authorization errors to the dedicated client auth error page", %{
      conn: conn
    } do
      account = account_fixture()
      Mocks.OIDC.stub_connection_refused()
      %{provider: provider} = setup_oidc_provider(account)

      log =
        capture_log(fn ->
          conn =
            get(conn, "/#{account.id}/sign_in/oidc/#{provider.id}", %{
              "as" => "client",
              "state" => "client-state",
              "nonce" => "client-nonce"
            })

          location = redirected_to(conn)
          assert String.starts_with?(location, "/#{account.slug}/sign_in/client_auth_error?")

          query =
            location
            |> URI.parse()
            |> Map.fetch!(:query)
            |> URI.decode_query()

          assert query["as"] == "client"
          assert query["state"] == "client-state"
          assert query["nonce"] == "client-nonce"

          assert query["error"] ==
                   "Unable to fetch discovery document: Connection refused. The identity provider may be down."
        end)

      assert log =~ "OIDC sign-in redirecting with error"
      assert log =~ "account_id=#{account.id}"

      assert log =~
               "Unable to fetch discovery document: Connection refused. The identity provider may be down."
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

  defp unique_email do
    "admin-#{System.unique_integer([:positive, :monotonic])}@example.com"
  end

  # Builds an OIDC auth state map for cookie-backed callbacks.
  defp build_oidc_auth_state(account, provider, opts \\ []) do
    %{
      auth_provider_type: "oidc",
      auth_provider_id: provider.id,
      account_id: account.id,
      account_slug: account.slug,
      verifier: Keyword.get(opts, :verifier, "test-verifier"),
      params: Keyword.get(opts, :params, %{})
    }
  end

  # Performs OIDC callback by putting auth state into the oidc cookie and calling the callback.
  # The `seed_via_sign_in` option is accepted for backward compatibility but ignored —
  # the cookie approach doesn't require going through the sign_in endpoint first.
  defp perform_callback(conn, auth_state, opts \\ []) do
    code = Keyword.get(opts, :code, "test-code")
    state = Keyword.get(opts, :state, Ecto.UUID.generate())

    cookie = %Cookie.AuthenticationState{
      auth_provider_type: auth_state.auth_provider_type,
      auth_provider_id: auth_state.auth_provider_id,
      account_id: auth_state.account_id,
      account_slug: auth_state.account_slug,
      verifier: auth_state.verifier,
      params: auth_state.params || %{},
      state: state
    }

    conn
    |> with_endpoint_key_base()
    |> Cookie.AuthenticationState.put(cookie)
    |> recycle()
    |> copy_req_headers(conn, @request_context_headers)
    |> get(~p"/auth/oidc/callback", %{"state" => state, "code" => code})
  end

  defp copy_req_headers(conn, source_conn, headers) do
    Enum.reduce(headers, conn, fn header, conn ->
      case Plug.Conn.get_req_header(source_conn, header) do
        [] -> conn
        [value | _rest] -> Plug.Conn.put_req_header(conn, header, value)
      end
    end)
  end

  # Reads the oidc cookie from a response conn by recycling it to make cookies readable.
  defp oidc_cookie_from_response(conn) do
    conn
    |> recycle()
    |> with_endpoint_key_base()
    |> Cookie.AuthenticationState.fetch()
  end

  defp pending_identity_cookie_from_response(conn) do
    pending_identity_id =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("pending_identity_id")

    conn
    |> recycle()
    |> with_endpoint_key_base()
    |> Cookie.PendingIdentity.fetch(pending_identity_id)
  end

  defp put_pending_identity_req_cookie(conn, response_conn, pending_identity_id) do
    Plug.Test.put_req_cookie(
      conn,
      pending_identity_cookie_key(pending_identity_id),
      response_conn.resp_cookies[pending_identity_cookie_key(pending_identity_id)].value
    )
  end

  defp pending_identity_cookie_key(pending_identity_id), do: "pending_identity_#{pending_identity_id}"

  # Sets the secret_key_base from the endpoint so signed cookies can be read/written.
  defp with_endpoint_key_base(conn) do
    Map.put(conn, :secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
  end

  defp auth_state_from_redirect(conn) do
    uri = redirected_to(conn) |> URI.parse()

    case uri.query do
      nil -> nil
      query -> query |> URI.decode_query() |> Map.get("state")
    end
  end

  defp oidc_verification_result_from_redirect(redirect_url) do
    result_token =
      redirect_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("result")

    Phoenix.Token.verify(PortalWeb.Endpoint, "oidc-verification-result", result_token,
      max_age: 60
    )
  end

  defp entra_verification_result_from_redirect(redirect_url) do
    result_token =
      redirect_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("result")

    Phoenix.Token.verify(PortalWeb.Endpoint, "entra-verification-result", result_token,
      max_age: 60
    )
  end

  defp assert_tenant_proof_redirect(conn, expected_scope, expected_prompt) do
    uri = conn |> redirected_to() |> URI.parse()
    params = URI.decode_query(uri.query)

    assert uri.host == "login.microsoftonline.com"
    assert uri.path == "/#{@tenant_id}/oauth2/v2.0/authorize"
    assert params["scope"] == expected_scope
    assert params["response_type"] == "code"
    assert params["code_challenge_method"] == "S256"
    assert params["prompt"] == expected_prompt
    assert is_binary(params["state"])
    refute params["state"] == ""
  end

  defp complete_entra_admin_consent(conn, state, extra_params \\ %{}) do
    params =
      %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => @tenant_id
      }
      |> Map.merge(extra_params)

    get(recycle(conn), ~p"/auth/oidc/callback", params)
  end

  defp complete_entra_tenant_proof(conn, extra_params \\ %{}) do
    params =
      %{
        "state" => callback_state_from_redirect(conn),
        "code" => "test-code"
      }
      |> Map.merge(extra_params)

    get(recycle(conn), ~p"/auth/oidc/callback", params)
  end

  defp callback_state_from_redirect(conn) do
    conn
    |> redirected_to()
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp entra_verification_config(client_id) do
    {scope, admin_consent_scope} =
      if client_id == "entra-sync-client-id" do
        {"openid profile", "https://graph.microsoft.com/.default"}
      else
        {"openid email profile", "openid email profile"}
      end

    %{
      admin_consent_scope: admin_consent_scope,
      client_id: client_id,
      client_secret: "test-secret",
      discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
      redirect_uri: PortalWeb.OIDC.callback_url(),
      response_type: "code",
      scope: scope,
      verification_client_auth: :entra,
      req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
    }
  end

  defp pending_verification_process(config, verification_ref) do
    pending = %{
      config: config,
      verifier: "test-verifier",
      verification_ref: verification_ref
    }

    spawn(fn -> pending_verification_loop(pending) end)
  end

  defp configure_google_directory_workload_identity do
    Portal.Config.put_env_override(
      :portal,
      Portal.Google.APIClient,
      workload_identity_provider: "google-workload-identity-provider",
      workload_identity_audience: "google-workload-identity-audience",
      service_account_email: "directory-sync@example.iam.gserviceaccount.com",
      service_account_key: nil
    )
  end

  defp set_google_directory_id_token(overrides) do
    claims =
      Mocks.OIDC.default_claims()
      |> Map.put("hd", "example.com")
      |> Map.merge(overrides)

    Mocks.OIDC.set_token_response(%{
      "id_token" => Mocks.OIDC.sign_openid_connect_token(claims)
    })
  end

  defp expect_google_directory_admin_check(email, customer_response) do
    Req.Test.expect(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "azure-managed-identity-token",
        "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
      })
    end)

    Req.Test.expect(Portal.Google.APIClient, 4, fn conn ->
      case conn.request_path do
        "/v1/token" ->
          Req.Test.json(conn, %{
            "access_token" => "federated-google-token",
            "expires_in" => 3600
          })

        "/v1/projects/-/serviceAccounts/" <>
            "directory-sync@example.iam.gserviceaccount.com:signJwt" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Bearer federated-google-token"
                 ]

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"payload" => payload} = JSON.decode!(body)
          claims = JSON.decode!(payload)

          assert claims["sub"] == email

          assert claims["scope"] ==
                   "https://www.googleapis.com/auth/admin.directory.customer.readonly"

          Req.Test.json(conn, %{"signedJwt" => "customer-read-signed-jwt"})

        "/oauth2.googleapis.com/token" ->
          flunk("Google token exchange used an unexpected endpoint")

        "/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          assert params["assertion"] == "customer-read-signed-jwt"

          Req.Test.json(conn, %{
            "access_token" => "delegated-customer-read-token",
            "expires_in" => 3600
          })

        "/admin/directory/v1/customers/my_customer" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Bearer delegated-customer-read-token"
                 ]

          google_customer_test_response(conn, customer_response)
      end
    end)
  end

  defp google_customer_test_response(conn, {:ok, body}), do: Req.Test.json(conn, body)

  defp google_customer_test_response(conn, {:error, status, body}) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end

  defp google_directory_pending_verification_process(verification_ref, workspace_customer_id) do
    pending = %{
      config: oidc_config(),
      verifier: "test-verifier",
      verification_ref: verification_ref,
      workspace_customer_id: workspace_customer_id
    }

    spawn(fn -> pending_verification_loop(pending) end)
  end

  defp google_directory_verification_state(lv_pid, verification_ref) do
    lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)

    PortalWeb.OIDC.sign_verification_state(lv_pid_string, "google-directory-sync", %{
      verification_ref: verification_ref
    })
  end

  defp pending_verification_loop(pending) do
    receive do
      {:peek_pending_verification, from} ->
        send(from, {:pending_verification, pending})
        pending_verification_loop(pending)

      {:get_pending_verification, from} ->
        send(from, {:pending_verification, pending})
        pending_verification_loop(nil)

      {:get_pending_verification, verification_ref, from} ->
        case pending do
          %{verification_ref: ^verification_ref} ->
            send(from, {:pending_verification, pending})
            pending_verification_loop(nil)

          _pending ->
            send(from, {:pending_verification, nil})
            pending_verification_loop(pending)
        end
    end
  end

  defp entra_verification_state(lv_pid, type, verification_ref) do
    lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)

    PortalWeb.OIDC.sign_verification_state(lv_pid_string, type, %{
      verification_ref: verification_ref
    })
  end

  defp entra_tenant_proof_state(lv_pid, type, verification_ref) do
    lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)

    PortalWeb.OIDC.sign_verification_state(lv_pid_string, "#{type}-tenant-proof", %{
      verification_ref: verification_ref,
      tenant_id: @tenant_id,
      silent: true
    })
  end

  defp set_entra_token_response(client_id, claim_overrides \\ %{}) do
    client_id
    |> entra_claims()
    |> Map.merge(claim_overrides)
    |> set_entra_claims_response()
  end

  defp set_entra_claims_response(claims) do
    Mocks.OIDC.set_discovery_document_overrides(%{
      "issuer" => "https://login.microsoftonline.com/{tenantid}/v2.0"
    })

    claims
    |> Mocks.OIDC.sign_openid_connect_token()
    |> set_entra_id_token_response()
  end

  defp set_entra_id_token_response(id_token) do
    Mocks.OIDC.set_token_response(%{
      "access_token" => "test-access-token",
      "token_type" => "Bearer",
      "id_token" => id_token
    })
  end

  defp entra_claims(client_id) do
    Mocks.OIDC.default_claims()
    |> Map.merge(%{
      "aud" => client_id,
      "iss" => "https://login.microsoftonline.com/12345678-1234-1234-1234-123456789012/v2.0",
      "nonce" => entra_nonce("test-verifier"),
      "oid" => "87654321-4321-4321-4321-210987654321",
      "wids" => ["62e90394-69f5-4237-9190-012177145e10"],
      "tid" => "12345678-1234-1234-1234-123456789012"
    })
  end

  defp invalidate_jwt_signature(id_token) do
    [header, payload, signature] = String.split(id_token, ".")
    replacement = if String.starts_with?(signature, "A"), do: "B", else: "A"
    invalid_signature = replacement <> String.slice(signature, 1..-1//1)
    Enum.join([header, payload, invalid_signature], ".")
  end

  defp flush_oidc_requests do
    receive do
      {:oidc_request, _path, _conn} -> flush_oidc_requests()
    after
      0 -> :ok
    end
  end

  defp entra_nonce(verifier) do
    :crypto.hash(:sha256, "entra-verification-nonce:" <> verifier)
    |> Base.url_encode64(padding: false)
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
    email = Keyword.get(opts, :email, actor.email)

    claims =
      %{
        "iss" => provider.issuer,
        "email" => email,
        "sub" => sub,
        "aud" => provider.client_id,
        "exp" => token_exp(),
        "nonce" => Keyword.get(opts, :nonce, PortalWeb.OIDC.nonce("test-verifier"))
      }
      |> maybe_add_email_verified(opts)
      |> maybe_add_claim("name", opts, actor.name)
      |> maybe_add_claim("given_name", opts)
      |> maybe_add_claim("family_name", opts)
      |> maybe_add_claim("preferred_username", opts)
      |> maybe_add_claim("nickname", opts)

    Mocks.OIDC.sign_openid_connect_token(claims)
  end

  defp maybe_add_email_verified(claims, opts) do
    case Keyword.fetch(opts, :email_verified) do
      {:ok, :omit} -> claims
      {:ok, value} -> Map.put(claims, "email_verified", value)
      :error -> Map.put(claims, "email_verified", true)
    end
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

  defp assert_oidc_nonce_bound(conn) do
    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    cookie = oidc_cookie_from_response(conn)

    assert params["nonce"] == PortalWeb.OIDC.nonce(cookie.verifier)
  end

  # Sets up the userinfo endpoint mock response.
  defp expect_userinfo(actor, opts) do
    sub = Keyword.get(opts, :sub, "admin-user-123")
    email_verified = Keyword.get(opts, :email_verified, true)
    email = Keyword.get(opts, :email, actor.email)

    userinfo =
      %{
        "sub" => sub,
        "email" => email,
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
    assert conn.resp_body =~ "/#{ctx.account.slug}/sign_in/client_redirect"
    refute conn.resp_body =~ "/#{ctx.account.id}/sign_in/client_redirect"
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
    assert conn.resp_body =~ "/#{ctx.account.slug}/sign_in/client_redirect"
    refute conn.resp_body =~ "/#{ctx.account.id}/sign_in/client_redirect"
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
    assert conn.resp_body =~ "Copy to clipboard"
    # Headless client should NOT set client_auth cookie
    refute conn.resp_cookies["client_auth"]

    conn
  end

  defp oidc_config do
    Application.fetch_env!(:portal, Portal.OIDC.AuthProvider)
    |> Keyword.merge(
      discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
      client_id: "test-client",
      client_secret: "test-secret",
      redirect_uri: PortalWeb.OIDC.callback_url()
    )
    |> Enum.into(%{})
  end
end
