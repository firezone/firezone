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
end
