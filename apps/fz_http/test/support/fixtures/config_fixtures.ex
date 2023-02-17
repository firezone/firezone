defmodule FzHttp.ConfigFixtures do
  @moduledoc """
  Allows for easily updating configuration in tests.
  """
  alias FzHttp.Repo
  alias FzHttp.Config

  def configuration(%Config.Configuration{} = conf \\ Config.fetch_db_config!(), attrs) do
    {:ok, configuration} =
      conf
      |> Config.Configuration.Changeset.changeset(attrs)
      |> Repo.update()

    configuration
  end

  def start_openid_providers(provider_names, overrides \\ %{}) do
    {bypass, discovery_document_url} = discovery_document_server()

    openid_connect_providers_attrs =
      discovery_document_url
      |> openid_connect_providers_attrs()
      |> Enum.filter(&(&1["id"] in provider_names))
      |> Enum.map(fn config ->
        config
        |> Enum.into(%{})
        |> Map.merge(overrides)
      end)

    Config.put_config!(:openid_connect_providers, openid_connect_providers_attrs)

    {bypass, openid_connect_providers_attrs}
  end

  defp openid_connect_providers_attrs(discovery_document_url) do
    [
      %{
        "id" => "google",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "google-client-id",
        "client_secret" => "google-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/google/callback/",
        "response_type" => "code",
        "scope" => "openid email profile",
        "label" => "OIDC Google",
        "auto_create_users" => false
      },
      %{
        "id" => "okta",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "okta-client-id",
        "client_secret" => "okta-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/okta/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Okta",
        "auto_create_users" => false
      },
      %{
        "id" => "auth0",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "auth0-client-id",
        "client_secret" => "auth0-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/auth0/callback/",
        "response_type" => "code",
        "scope" => "openid email profile",
        "label" => "OIDC Auth0",
        "auto_create_users" => false
      },
      %{
        "id" => "azure",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "azure-client-id",
        "client_secret" => "azure-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/azure/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Azure",
        "auto_create_users" => false
      },
      %{
        "id" => "onelogin",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "onelogin-client-id",
        "client_secret" => "onelogin-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/onelogin/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Onelogin",
        "auto_create_users" => false
      },
      %{
        "id" => "keycloak",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "keycloak-client-id",
        "client_secret" => "keycloak-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/keycloak/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Keycloak",
        "auto_create_users" => false
      },
      %{
        "id" => "vault",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "vault-client-id",
        "client_secret" => "vault-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/vault/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Vault",
        "auto_create_users" => false
      }
    ]
  end

  def jwks_attrs do
    %{
      "alg" => "RS256",
      "d" =>
        "X8TM24Zqbiha9geYYk_vZpANu16IadJLJLJ7ucTc3JaMbK8NCYNcHMoXKnNYPFxmq-UWAEIwh-2" <>
          "txOiOxuChVrblpfyE4SBJio1T0AUcCwmm8U6G-CsSHMMzWTt2dMTnArHjdyAIgOVRW5SVzhTT" <>
          "taf4JY-47S-fbcJ7g0hmBbVih5i1sE2fad4I4qFHT-YFU_pnUHbteR6GQuRW4r03Eon8Aje6a" <>
          "l2AxcYnfF8_cSOIOpkDgGavTtGYhhZPi2jZ7kPm6QGkNW5CyfEq5PGB6JOihw-XIFiiMzYgx0" <>
          "52rnzoqALoLheXrI0By4kgHSmcqOOmq7aiOff45rlSbpsR",
      "e" => "AQAB",
      "kid" => "example@firezone.dev",
      "kty" => "RSA",
      "n" =>
        "qlKll8no4lPYXNSuTTnacpFHiXwPOv_htCYvIXmiR7CWhiiOHQqj7KWXIW7TGxyoLVIyeRM4mwv" <>
          "kLI-UgsSMYdEKTT0j7Ydjrr0zCunPu5Gxr2yOmcRaszAzGxJL5DwpA0V40RqMlm5OuwdqS4To" <>
          "_p9LlLxzMF6RZe1OqslV5RZ4Y8FmrWq6BV98eIziEHL0IKdsAIrrOYkkcLDdQeMNuTp_yNB8X" <>
          "l2TdWSdsbRomrs2dCtCqZcXTsy2EXDceHvYhgAB33nh_w17WLrZQwMM-7kJk36Kk54jZd7i80" <>
          "AJf_s_plXn1mEh-L5IAL1vg3a9EOMFUl-lPiGqc3td_ykH",
      "use" => "sig"
    }
  end

  def expect_refresh_token(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/oauth/token", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)
  end

  def expect_refresh_token_failure(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/oauth/token", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 401, Jason.encode!(attrs))
    end)
  end

  def discovery_document_server do
    bypass = Bypass.open()
    endpoint = "http://localhost:#{bypass.port}"
    test_pid = self()

    Bypass.expect(bypass, "GET", "/.well-known/jwks.json", fn conn ->
      attrs = %{"keys" => [jwks_attrs()]}
      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)

    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})

      attrs = %{
        "issuer" => "#{endpoint}/",
        "authorization_endpoint" => "#{endpoint}/authorize",
        "token_endpoint" => "#{endpoint}/oauth/token",
        "device_authorization_endpoint" => "#{endpoint}/oauth/device/code",
        "userinfo_endpoint" => "#{endpoint}/userinfo",
        "mfa_challenge_endpoint" => "#{endpoint}/mfa/challenge",
        "jwks_uri" => "#{endpoint}/.well-known/jwks.json",
        "registration_endpoint" => "#{endpoint}/oidc/register",
        "revocation_endpoint" => "#{endpoint}/oauth/revoke",
        "end_session_endpoint" => "https://example.com",
        "scopes_supported" => [
          "openid",
          "profile",
          "offline_access",
          "name",
          "given_name",
          "family_name",
          "nickname",
          "email",
          "email_verified",
          "picture",
          "created_at",
          "identities",
          "phone",
          "address"
        ],
        "response_types_supported" => [
          "code",
          "token",
          "id_token",
          "code token",
          "code id_token",
          "token id_token",
          "code token id_token"
        ],
        "code_challenge_methods_supported" => [
          "S256",
          "plain"
        ],
        "response_modes_supported" => [
          "query",
          "fragment",
          "form_post"
        ],
        "subject_types_supported" => [
          "public"
        ],
        "id_token_signing_alg_values_supported" => [
          "HS256",
          "RS256"
        ],
        "token_endpoint_auth_methods_supported" => [
          "client_secret_basic",
          "client_secret_post"
        ],
        "claims_supported" => [
          "aud",
          "auth_time",
          "created_at",
          "email",
          "email_verified",
          "exp",
          "family_name",
          "given_name",
          "iat",
          "identities",
          "iss",
          "name",
          "nickname",
          "phone_number",
          "picture",
          "sub"
        ],
        "request_uri_parameter_supported" => false,
        "request_parameter_supported" => false
      }

      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)

    {bypass, "#{endpoint}/.well-known/openid-configuration"}
  end

  def fetch_conn_params(conn) do
    opts = Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)

    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Parsers.call(opts)
  end

  def saml_identity_providers_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "metadata" => saml_metadata(),
      "label" => "test",
      "id" => "test",
      "auto_create_users" => true
    })
  end

  def saml_metadata do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <md:EntityDescriptor entityID="http://www.okta.com/exk6ff6p62kFjUR3X5d7"
      xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata">
      <md:IDPSSODescriptor WantAuthnRequestsSigned="false" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
        <md:KeyDescriptor use="signing">
          <ds:KeyInfo
            xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
            <ds:X509Data>
              <ds:X509Certificate>MIIDqDCCApCgAwIBAgIGAYMaIfiKMA0GCSqGSIb3DQEBCwUAMIGUMQswCQYDVQQGEwJVUzETMBEG
    A1UECAwKQ2FsaWZvcm5pYTEWMBQGA1UEBwwNU2FuIEZyYW5jaXNjbzENMAsGA1UECgwET2t0YTEU
    MBIGA1UECwwLU1NPUHJvdmlkZXIxFTATBgNVBAMMDGRldi04Mzg1OTk1NTEcMBoGCSqGSIb3DQEJ
    ARYNaW5mb0Bva3RhLmNvbTAeFw0yMjA5MDcyMjQ1MTdaFw0zMjA5MDcyMjQ2MTdaMIGUMQswCQYD
    VQQGEwJVUzETMBEGA1UECAwKQ2FsaWZvcm5pYTEWMBQGA1UEBwwNU2FuIEZyYW5jaXNjbzENMAsG
    A1UECgwET2t0YTEUMBIGA1UECwwLU1NPUHJvdmlkZXIxFTATBgNVBAMMDGRldi04Mzg1OTk1NTEc
    MBoGCSqGSIb3DQEJARYNaW5mb0Bva3RhLmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
    ggEBAOmj276L3kHm57hNGYTocT6NS4mffPbcvsA2UuKIWfmpV8HLTcmS+NahLtuN841OnRnTn+2p
    fjlwa1mwJhCODbF3dcVYOkGTPUC4y2nvf1Xas6M7+0O2WIfrzdX/OOUs/ROMnB/O/MpBwMR2SQh6
    Q3V+9v8g3K9yfMvcifDbl6g9fTliDzqV7I9xF5eJykl+iCAKNaQgp3cO6TaIa5u2ZKtRAdzwnuJC
    BXMyzaoNs/vfnwzuFtzWP1PSS1Roan+8AMwkYA6BCr1YRIqZ0GSkr/qexFCTZdq0UnSN78fY6CCM
    RFw5wU0WM9nEpbWzkBBWsYHeTLo5JqR/mZukfjlPDlcCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEA
    lUhwzCSnuqt4wlHxJONN4kxUBG8bPnjHxob6jBKK+onFDuSVWZ+7LZw67blz6xdxvlOLaQLi1fK2
    Fifehbc7KbRLckcgNgg7Y8qfUKdP0/nS0JlyAvlnICQqaHTHwhIzQqTHtTZeeIJHtpWOX/OPRI0S
    bkygh2qjF8bYn3sX8bGNUQL8iiMxFnvwGrXaErPqlRqFJbWQDBXD+nYDIBw7WN3Jyb0Ydin2zrlh
    gp3Qooi0TnAir3ncw/UF/+sivCgd+6nX7HkbZtipkMbg7ZByyD9xrOQG2JXrP6PyzGCPwnGMt9pL
    iiVMepeLNqKZ3UvhrR1uRN0KWu7lduIRhxldLA==</ds:X509Certificate>
            </ds:X509Data>
          </ds:KeyInfo>
        </md:KeyDescriptor>
        <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified</md:NameIDFormat>
        <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat>
        <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="https://dev-83859955.okta.com/app/dev-83859955_firezonesaml_1/exk6ff6p62kFjUR3X5d7/sso/saml"/>
        <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="https://dev-83859955.okta.com/app/dev-83859955_firezonesaml_1/exk6ff6p62kFjUR3X5d7/sso/saml"/>
      </md:IDPSSODescriptor>
    </md:EntityDescriptor>
    """
  end
end
