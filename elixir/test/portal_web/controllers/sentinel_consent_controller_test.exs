defmodule PortalWeb.SentinelConsentControllerTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Mocks

  @client_id "test_sentinel_client_id"
  @tenant_id "12345678-1234-1234-1234-123456789012"
  @other_tenant_id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @global_administrator "62e90394-69f5-4237-9190-012177145e10"
  @verifier_session_key :sentinel_consent_verifier
  @verification_ref "b3d6f0a2-1c3e-4a5b-9d7f-2e4c6a8b0d1f"

  setup do
    Mocks.OIDC.stub_discovery_document()

    Portal.Config.put_env_override(:portal, Portal.Sentinel.APIClient,
      discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
      req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
    )

    :ok
  end

  describe "callback/2 admin consent" do
    test "starts a silent tenant proof against the tenant Entra reports", %{conn: conn} do
      conn = grant_admin_consent(conn)

      params = redirect_params(conn)

      assert redirect_uri(conn).host == "login.microsoftonline.com"
      assert redirect_uri(conn).path == "/#{@tenant_id}/oauth2/v2.0/authorize"
      assert params["client_id"] == @client_id
      assert params["response_type"] == "code"
      assert params["scope"] == "openid profile"
      assert params["prompt"] == "none"
      assert params["code_challenge_method"] == "S256"
      assert params["redirect_uri"] == url(~p"/auth/sentinel/consent")
      assert is_binary(Plug.Conn.get_session(conn, @verifier_session_key))
    end

    test "declines when Entra returns an error alongside admin_consent", %{conn: conn} do
      conn =
        grant_admin_consent(conn, %{
          "error" => "access_denied",
          "error_description" => "AADSTS650056: Misconfigured application."
        })

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "AADSTS650056"
      refute html =~ "Admin Consent Granted"
    end

    test "declines a consent response with no tenant", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/sentinel/consent", %{
          "state" => consent_state(),
          "admin_consent" => "True"
        })

      assert html_response(conn, 200) =~ "missing or invalid"
    end

    test "declines a malformed tenant", %{conn: conn} do
      conn = grant_admin_consent(conn, %{"tenant" => "attacker-controlled-tenant"})

      assert html_response(conn, 200) =~ "could not verify your Microsoft Entra tenant"
    end

    test "declines an unverifiable state", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/sentinel/consent", %{
          "state" => "acme",
          "admin_consent" => "True"
        })

      assert html_response(conn, 200) =~ "missing or invalid"
    end

    test "keeps the Entra error when the state can no longer be verified", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/sentinel/consent", %{
          "state" => "acme",
          "error" => "access_denied",
          "error_description" => "AADSTS65004: User declined to consent."
        })

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "AADSTS65004"
    end

    test "declines a response with no state", %{conn: conn} do
      conn = get(conn, ~p"/auth/sentinel/consent", %{})

      assert html_response(conn, 200) =~ "missing or invalid"
    end

    test "declines an authorization code carrying the admin consent state", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/sentinel/consent", %{
          "state" => consent_state(),
          "code" => "test-code"
        })

      assert html_response(conn, 200) =~ "missing or invalid"
    end
  end

  describe "callback/2 tenant proof" do
    test "renders the granted page for a verified tenant administrator", %{conn: conn} do
      conn = grant_admin_consent(conn)
      set_proof_token_response(conn)

      conn = complete_tenant_proof(conn)

      html = html_response(conn, 200)
      assert html =~ "Admin Consent Granted"
      assert html =~ @tenant_id
      assert html =~ ~s(data-auto-close-window-after-ms="1000")

      # Entra rejects the exchange unless it repeats the reply address the
      # authorization request used.
      assert token_request_params()["redirect_uri"] == url(~p"/auth/sentinel/consent")
    end

    test "sends the verified tenant back to the log sink form", %{conn: conn} do
      conn = grant_admin_consent(conn)
      set_proof_token_response(conn)

      complete_tenant_proof(conn)

      assert_received {:sentinel_log_sink_complete, @tenant_id, @verification_ref}
    end

    test "declines an ID token from a tenant other than the one that consented", %{conn: conn} do
      conn = grant_admin_consent(conn, %{"tenant" => @other_tenant_id})
      assert redirect_uri(conn).path == "/#{@other_tenant_id}/oauth2/v2.0/authorize"

      set_proof_token_response(conn)
      conn = complete_tenant_proof(conn)

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "could not confirm which Microsoft Entra tenant"
      refute_received {:sentinel_log_sink_complete, _tenant_id, _verification_ref}
    end

    test "declines an administrator without a tenant-wide admin role", %{conn: conn} do
      conn = grant_admin_consent(conn)
      set_proof_token_response(conn, %{"wids" => []})

      conn = complete_tenant_proof(conn)

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "Global Administrator"
      refute_received {:sentinel_log_sink_complete, _tenant_id, _verification_ref}
    end

    test "retries with an account picker when silent SSO is unavailable", %{conn: conn} do
      conn = grant_admin_consent(conn)
      conn = complete_tenant_proof(conn, %{"error" => "interaction_required", "code" => nil})

      params = redirect_params(conn)

      assert redirect_uri(conn).path == "/#{@tenant_id}/oauth2/v2.0/authorize"
      refute Map.has_key?(params, "prompt")
    end

    test "declines when the interactive retry also fails", %{conn: conn} do
      conn = grant_admin_consent(conn)
      conn = complete_tenant_proof(conn, %{"error" => "interaction_required", "code" => nil})
      conn = complete_tenant_proof(conn, %{"error" => "interaction_required", "code" => nil})

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "interaction_required"
    end

    test "declines an error the silent retry cannot recover from", %{conn: conn} do
      conn = grant_admin_consent(conn)

      conn =
        complete_tenant_proof(conn, %{
          "error" => "access_denied",
          "error_description" => "AADSTS65004: User declined to consent.",
          "code" => nil
        })

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "AADSTS65004"
    end

    test "declines when the browser no longer holds the code verifier", %{conn: conn} do
      consent_conn = grant_admin_consent(conn)
      set_proof_token_response(consent_conn)

      conn =
        get(build_conn(), ~p"/auth/sentinel/consent", %{
          "state" => redirect_params(consent_conn) |> Map.fetch!("state"),
          "code" => "test-code"
        })

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "lost the consent session"
    end

    test "declines when the token exchange fails", %{conn: conn} do
      conn = grant_admin_consent(conn)
      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_grant"})

      conn = complete_tenant_proof(conn)

      html = html_response(conn, 200)
      assert html =~ "Consent Was Not Granted"
      assert html =~ "could not verify your Microsoft Entra tenant"
    end
  end

  defp consent_state(verification_ref \\ @verification_ref) do
    PortalWeb.OIDC.sign_verification_state(
      PortalWeb.OIDC.serialize_pid(self()),
      "sentinel-log-sink",
      %{verification_ref: verification_ref}
    )
  end

  defp grant_admin_consent(conn, extra_params \\ %{}) do
    params =
      %{
        "state" => consent_state(),
        "admin_consent" => "True",
        "tenant" => @tenant_id
      }
      |> Map.merge(extra_params)

    get(conn, ~p"/auth/sentinel/consent", params)
  end

  defp complete_tenant_proof(conn, extra_params \\ %{}) do
    params =
      %{
        "state" => redirect_params(conn) |> Map.fetch!("state"),
        "code" => "test-code"
      }
      |> Map.merge(extra_params)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    get(recycle(conn), ~p"/auth/sentinel/consent", params)
  end

  defp set_proof_token_response(conn, claim_overrides \\ %{}) do
    verifier = Plug.Conn.get_session(conn, @verifier_session_key)

    claims =
      Mocks.OIDC.default_claims()
      |> Map.merge(%{
        "aud" => @client_id,
        "iss" => "https://login.microsoftonline.com/#{@tenant_id}/v2.0",
        "nonce" => entra_nonce(verifier),
        "oid" => "87654321-4321-4321-4321-210987654321",
        "tid" => @tenant_id,
        "wids" => [@global_administrator]
      })
      |> Map.merge(claim_overrides)

    Mocks.OIDC.set_discovery_document_overrides(%{
      "issuer" => "https://login.microsoftonline.com/{tenantid}/v2.0"
    })

    Mocks.OIDC.set_token_response(%{
      "access_token" => "test-access-token",
      "token_type" => "Bearer",
      "id_token" => Mocks.OIDC.sign_openid_connect_token(claims)
    })
  end

  defp entra_nonce(verifier) do
    :crypto.hash(:sha256, "entra-verification-nonce:" <> verifier)
    |> Base.url_encode64(padding: false)
  end

  defp token_request_params do
    receive do
      {:oidc_request, path, request_conn} ->
        case String.ends_with?(path, "/oauth/token") do
          true -> request_conn.body_params
          false -> token_request_params()
        end
    after
      0 -> flunk("the tenant proof made no token request")
    end
  end

  defp redirect_uri(conn) do
    conn |> redirected_to() |> URI.parse()
  end

  defp redirect_params(conn) do
    conn |> redirect_uri() |> Map.fetch!(:query) |> URI.decode_query()
  end
end
