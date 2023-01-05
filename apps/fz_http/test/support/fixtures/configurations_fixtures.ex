defmodule FzHttp.ConfigurationsFixtures do
  @moduledoc """
  Allows for easily updating configuration in tests.
  """

  alias FzHttp.{
    Configurations,
    Configurations.Configuration,
    Repo
  }

  @doc "Configurations table holds a singleton record."
  def configuration(%Configuration{} = conf \\ Configurations.get_configuration!(), attrs) do
    {:ok, configuration} =
      conf
      |> Configuration.changeset(attrs)
      |> Repo.update()

    configuration
  end

  def openid_connect_providers_attrs do
    discovery_document_url = discovery_document_server()

    [
      %{
        "id" => "google",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "google-client-id",
        "client_secret" => "google-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/google/callback/",
        "response_type" => "code",
        "scope" => "openid email profile",
        "label" => "OIDC Google"
      },
      %{
        "id" => "okta",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "okta-client-id",
        "client_secret" => "okta-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/okta/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Okta"
      },
      %{
        "id" => "auth0",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "auth0-client-id",
        "client_secret" => "auth0-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/auth0/callback/",
        "response_type" => "code",
        "scope" => "openid email profile",
        "label" => "OIDC Auth0"
      },
      %{
        "id" => "azure",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "azure-client-id",
        "client_secret" => "azure-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/azure/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Azure"
      },
      %{
        "id" => "onelogin",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "onelogin-client-id",
        "client_secret" => "onelogin-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/onelogin/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Onelogin"
      },
      %{
        "id" => "keycloak",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "keycloak-client-id",
        "client_secret" => "keycloak-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/keycloak/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Keycloak"
      },
      %{
        "id" => "vault",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "vault-client-id",
        "client_secret" => "vault-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/vault/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Vault"
      }
    ]
  end

  def discovery_document_server do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      attrs = %{
        "issuer" => "https://common.auth0.com/",
        "authorization_endpoint" => "https://common.auth0.com/authorize",
        "token_endpoint" => "https://common.auth0.com/oauth/token",
        "device_authorization_endpoint" => "https://common.auth0.com/oauth/device/code",
        "userinfo_endpoint" => "https://common.auth0.com/userinfo",
        "mfa_challenge_endpoint" => "https://common.auth0.com/mfa/challenge",
        "jwks_uri" => "https://common.auth0.com/.well-known/jwks.json",
        "registration_endpoint" => "https://common.auth0.com/oidc/register",
        "revocation_endpoint" => "https://common.auth0.com/oauth/revoke",
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

    "http://localhost:#{bypass.port}/.well-known/openid-configuration"
  end

  def saml_identity_providers_attrs do
    [
      %{"id" => "test", "label" => "SAML"}
    ]
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
