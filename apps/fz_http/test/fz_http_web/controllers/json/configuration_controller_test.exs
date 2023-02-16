defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.ApiCase, async: true
  alias FzHttp.SAMLIdentityProviderFixtures

  describe "GET /v0/configuration" do
    test "renders configuration" do
      conn =
        get(authed_conn(), ~p"/v0/configuration")
        |> doc()

      assert json_response(conn, 200)["data"]
    end

    test "renders logotype" do
      FzHttp.Config.put_config!(:logo, %{"url" => "https://example.com/logo.png"})

      conn = get(authed_conn(), ~p"/v0/configuration")

      assert %{
               "logo" => %{
                 "data" => nil,
                 "type" => nil,
                 "url" => "https://example.com/logo.png"
               }
             } = json_response(conn, 200)["data"]
    end

    test "renders 401 for missing authorization header" do
      conn = get(unauthed_conn(), ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "PUT /v0/configuration" do
    test "updates fields when data is valid" do
      attrs = %{
        "local_auth_enabled" => false,
        "allow_unprivileged_device_management" => false,
        "allow_unprivileged_device_configuration" => false,
        "openid_connect_providers" => [
          %{
            "id" => "google",
            "label" => "google",
            "scope" => "email openid",
            "response_type" => "code",
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
            "metadata" => SAMLIdentityProviderFixtures.metadata(),
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
        "default_client_dns" => ["1.1.1.1"],
        "default_client_allowed_ips" => ["1.1.1.1", "2.2.2.2"]
      }

      conn =
        put(authed_conn(), ~p"/v0/configuration", configuration: attrs)
        |> doc()

      {generated_attrs, update_attrs} =
        Map.split(json_response(conn, 200)["data"], ~w[id inserted_at logo updated_at])

      assert update_attrs == attrs
      assert %{"id" => _, "inserted_at" => _, "logo" => _, "updated_at" => _} = generated_attrs

      attrs = %{
        "local_auth_enabled" => true,
        "allow_unprivileged_device_management" => true,
        "allow_unprivileged_device_configuration" => true,
        "openid_connect_providers" => [
          %{
            "id" => "google",
            "label" => "google-label",
            "scope" => "email openid",
            "response_type" => "code",
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
            "metadata" => SAMLIdentityProviderFixtures.metadata(),
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
        "default_client_dns" => ["4.4.4.4"],
        "default_client_allowed_ips" => ["8.8.8.8"]
      }

      conn = put(authed_conn(), ~p"/v0/configuration", configuration: attrs)

      {generated_attrs, update_attrs} =
        Map.split(json_response(conn, 200)["data"], ~w[id inserted_at logo updated_at])

      assert update_attrs == attrs
      assert %{"id" => _, "inserted_at" => _, "logo" => _, "updated_at" => _} = generated_attrs
    end

    test "renders errors when data is invalid" do
      conn =
        put(authed_conn(), ~p"/v0/configuration", configuration: %{"local_auth_enabled" => 123})

      assert json_response(conn, 422)["errors"] == %{"local_auth_enabled" => ["is invalid"]}
    end

    test "renders error when trying to override a value with environment override" do
      FzHttp.Config.put_system_env_override(:local_auth_enabled, true)

      attrs = %{
        "local_auth_enabled" => false
      }

      conn =
        put(authed_conn(), ~p"/v0/configuration", configuration: attrs)
        |> doc()

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "local_auth_enabled" => [
                   "can not be changed in UI, it is overridden by LOCAL_AUTH_ENABLED environment variable"
                 ]
               }
             }
    end

    test "renders 401 for missing authorization header" do
      conn = put(unauthed_conn(), ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
