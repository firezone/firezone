%{
  status_code: 200,
  body: %{
    "authorization_endpoint" =>
      "http://0.0.0.0:8200/ui/vault/identity/oidc/provider/default/authorize",
    "claims_supported" => [],
    "grant_types_supported" => ["authorization_code"],
    "id_token_signing_alg_values_supported" => [
      "RS256",
      "RS384",
      "RS512",
      "ES256",
      "ES384",
      "ES512",
      "EdDSA"
    ],
    "issuer" => "http://0.0.0.0:8200/v1/identity/oidc/provider/default",
    "jwks_uri" => "http://0.0.0.0:8200/v1/identity/oidc/provider/default/.well-known/keys",
    "request_parameter_supported" => false,
    "request_uri_parameter_supported" => false,
    "response_types_supported" => ["code"],
    "scopes_supported" => ["openid"],
    "subject_types_supported" => ["public"],
    "token_endpoint" => "http://0.0.0.0:8200/v1/identity/oidc/provider/default/token",
    "token_endpoint_auth_methods_supported" => [
      "none",
      "client_secret_basic",
      "client_secret_post"
    ],
    "userinfo_endpoint" => "http://0.0.0.0:8200/v1/identity/oidc/provider/default/userinfo"
  },
  headers: [
    {"Cache-Control", "max-age=3600"},
    {"Content-Type", "application/json"},
    {"Strict-Transport-Security", "max-age=31536000; includeSubDomains"},
    {"Date", "Sat, 12 Nov 2022 19:50:54 GMT"}
  ]
}
