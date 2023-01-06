defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.ApiCase, async: true

  describe "[authed] GET /v0/configuration" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "renders configuration", %{conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 200)["data"]
    end
  end

  describe "[authed] PUT /v0/configuration" do
    import FzHttp.ConfigurationsFixtures

    setup _tags, do: {:ok, conn: authed_conn()}

    @first_config %{
      "local_auth_enabled" => false,
      "allow_unprivileged_device_management" => false,
      "allow_unprivileged_device_configuration" => false,
      "openid_connect_providers" => [
        %{
          "id" => "google",
          "label" => "google",
          "scope" => "test-scope",
          "response_type" => "response-type",
          "client_id" => "test-id",
          "client_secret" => "test-secret",
          "discovery_document_uri" =>
            "https://accounts.google.com/.well-known/openid-configuration",
          "redirect_uri" => "https://invalid",
          "auto_create_users" => false
        }
      ],
      "saml_identity_providers" => [
        %{
          "id" => "okta",
          "label" => "okta",
          "base_url" => "https://saml",
          "metadata" => saml_metadata(),
          "sign_requests" => false,
          "sign_metadata" => false,
          "signed_assertion_in_resp" => false,
          "signed_envelopes_in_resp" => false,
          "auto_create_users" => false
        }
      ],
      "disable_vpn_on_oidc_error" => true,
      "vpn_session_duration" => 100,
      "default_client_persistent_keepalive" => 1,
      "default_client_mtu" => 1100,
      "default_client_endpoint" => "new-endpoint",
      "default_client_dns" => "1.1.1.1",
      "default_client_allowed_ips" => "1.1.1.1,2.2.2.2"
    }

    @second_config %{
      "local_auth_enabled" => true,
      "allow_unprivileged_device_management" => true,
      "allow_unprivileged_device_configuration" => true,
      "openid_connect_providers" => [
        %{
          "id" => "google",
          "label" => "google-label",
          "scope" => "test-scope-2",
          "response_type" => "response-type-2",
          "client_id" => "test-id-2",
          "client_secret" => "test-secret-2",
          "discovery_document_uri" =>
            "https://accounts.google.com/.well-known/openid-configuration",
          "redirect_uri" => "https://invalid-2",
          "auto_create_users" => true
        }
      ],
      "saml_identity_providers" => [
        %{
          "id" => "okta",
          "label" => "okta-label",
          "base_url" => "https://saml-old",
          "metadata" => saml_metadata(),
          "sign_requests" => true,
          "sign_metadata" => true,
          "signed_assertion_in_resp" => true,
          "signed_envelopes_in_resp" => true,
          "auto_create_users" => true
        }
      ],
      "disable_vpn_on_oidc_error" => false,
      "vpn_session_duration" => 1,
      "default_client_persistent_keepalive" => 25,
      "default_client_mtu" => 1200,
      "default_client_endpoint" => "old-endpoint",
      "default_client_dns" => "4.4.4.4",
      "default_client_allowed_ips" => "8.8.8.8"
    }

    test "updates fields when data is valid", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: @first_config)
      assert @first_config = json_response(conn, 200)["data"]

      conn = put(conn, ~p"/v0/configuration", configuration: @second_config)
      assert @second_config = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => 123})
      assert json_response(conn, 422)["errors"] == %{"local_auth_enabled" => ["is invalid"]}
    end
  end

  describe "[unauthed] GET /v0/configuration" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] PUT /v0/configuration" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
