import Config

defmodule DBConfig do
  def config(db_url) when is_nil(db_url) do
    [
      username: "postgres",
      password: "postgres",
      database: "firezone_test",
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 64,
      queue_target: 1000
    ]
  end

  def config(db_url) do
    [
      url: db_url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 64,
      queue_target: 1000
    ]
  end
end

# Configure your database
db_url = System.get_env("DATABASE_URL")
config :fz_http, FzHttp.Repo, DBConfig.config(db_url)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fz_http, FzHttpWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "t5hsQU868q6aaI9jsCrso9Qhi7A9Lvy5/NjCnJ8t8f652jtRjcBpYJkm96E8Q5Ko",
  live_view: [
    signing_salt: "mgC0uvbIgQM7GT5liNSbzJJhvjFjhb7t"
  ],
  server: true

config :fz_http,
  mock_events_module_errors: false,
  local_auth_enabled: true,
  telemetry_module: FzCommon.MockTelemetry,
  supervision_tree_mode: :test,
  connectivity_checks_interval: 86_400,
  sql_sandbox: true,
  http_client: FzHttp.Mocks.HttpClient

# Print only warnings and errors during test
config :logger, level: :warn

config :ueberauth, Ueberauth,
  providers: [
    {:identity, {Ueberauth.Strategy.Identity, [callback_methods: ["POST"], uid_field: :email]}}
  ]

# OIDC auth for testing
config :fz_http, :openid_connect_providers, """
{
  "google": {
    "discovery_document_uri": "https://google/.well-known/openid-configuration",
    "client_id": "CLIENT_ID",
    "client_secret": "CLIENT_SECRET",
    "redirect_uri": "https://firezone.example.com/auth/oidc/google/callback/",
    "response_type": "code",
    "scope": "openid email profile",
    "label": "OIDC Google"
  },
  "okta": {
    "discovery_document_uri": "https://okta/.well-known/openid-configuration",
    "client_id": "CLIENT_ID",
    "client_secret": "CLIENT_SECRET",
    "redirect_uri": "https://firezone.example.com/auth/oidc/okta/callback/",
    "response_type": "code",
    "scope": "openid email profile offline_access",
    "label": "OIDC Okta"
  },
  "auth0": {
    "discovery_document_uri": "https://auth0/.well-known/openid-configuration",
    "client_id": "CLIENT_ID",
    "client_secret": "CLIENT_SECRET",
    "redirect_uri": "https://firezone.example.com/auth/oidc/google/callback/",
    "response_type": "code",
    "scope": "openid email profile",
    "label": "OIDC Google"
  },
  "azure": {
    "discovery_document_uri": "https://azure/.well-known/openid-configuration",
    "client_id": "CLIENT_ID",
    "client_secret": "CLIENT_SECRET",
    "redirect_uri": "https://firezone.example.com/auth/oidc/okta/callback/",
    "response_type": "code",
    "scope": "openid email profile offline_access",
    "label": "OIDC Okta"
  },
  "onelogin": {
    "discovery_document_uri": "https://onelogin/.well-known/openid-configuration",
    "client_id": "CLIENT_ID",
    "client_secret": "CLIENT_SECRET",
    "redirect_uri": "https://firezone.example.com/auth/oidc/okta/callback/",
    "response_type": "code",
    "scope": "openid email profile offline_access",
    "label": "OIDC Okta"
  },
  "keycloak": {
    "discovery_document_uri": "https://keycloak/.well-known/openid-configuration",
    "client_id": "CLIENT_ID",
    "client_secret": "CLIENT_SECRET",
    "redirect_uri": "https://firezone.example.com/auth/oidc/keycloak/callback/",
    "response_type": "code",
    "scope": "openid email profile offline_access",
    "label": "Keycloak"
  },
  "vault": {
    "discovery_document_uri": "https://vault/.well-known/openid-configuration",
    "client_id": "vault-client-id",
    "client_secret": "vault-client-secret",
    "redirect_uri": "https://firezone.example.com/auth/oidc/vault/callback/",
    "response_type": "code",
    "scope": "openid email profile offline_access",
    "label": "Vault"
  }
}
"""

config :fz_http, :saml_identity_providers, %{"test" => %{"label" => "SAML"}}

# Provide mock for HTTPClient
config :fz_http, :openid_connect, OpenIDConnect.Mock

config :fz_http, FzHttp.Mailer, adapter: Swoosh.Adapters.Test, from_email: "test@firez.one"

config :fz_vpn,
  # XXX: Bump test coverage by adding a stubbed out module for FzVpn.StatsPushService
  supervised_children: [FzVpn.Interface.WGAdapter.Sandbox, FzVpn.Server],
  wg_adapter: FzVpn.Interface.WGAdapter.Sandbox
