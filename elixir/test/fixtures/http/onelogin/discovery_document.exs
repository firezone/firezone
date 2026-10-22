%{
  status_code: 200,
  body: %{
    "acr_values_supported" => ["onelogin:nist:level:1:re-auth"],
    "authorization_endpoint" => "https://common.onelogin.com/oidc/2/auth",
    "claim_types_supported" => ["normal"],
    "claims_parameter_supported" => true,
    "claims_supported" => [
      "sub",
      "email",
      "preferred_username",
      "name",
      "updated_at",
      "given_name",
      "family_name",
      "locale",
      "groups",
      "email_verified",
      "params",
      "phone_number",
      "acr",
      "sid",
      "auth_time",
      "iss"
    ],
    "code_challenge_methods_supported" => ["S256"],
    "end_session_endpoint" => "https://common.onelogin.com/oidc/2/logout",
    "grant_types_supported" => [
      "authorization_code",
      "implicit",
      "refresh_token",
      "client_credentials",
      "password"
    ],
    "id_token_signing_alg_values_supported" => ["HS256", "RS256", "PS256"],
    "introspection_endpoint" => "https://common.onelogin.com/oidc/2/token/introspection",
    "introspection_endpoint_auth_methods_supported" => [
      "client_secret_basic",
      "client_secret_post",
      "none"
    ],
    "issuer" => "https://common.onelogin.com/oidc/2",
    "jwks_uri" => "https://common.onelogin.com/oidc/2/certs",
    "registration_endpoint" => "https://common.onelogin.com/oidc/2/register",
    "request_parameter_supported" => false,
    "request_uri_parameter_supported" => false,
    "response_modes_supported" => ["form_post", "fragment", "query"],
    "response_types_supported" => ["code", "id_token token", "id_token"],
    "revocation_endpoint" => "https://common.onelogin.com/oidc/2/token/revocation",
    "revocation_endpoint_auth_methods_supported" => [
      "client_secret_basic",
      "client_secret_post",
      "none"
    ],
    "scopes_supported" => ["openid", "name", "profile", "groups", "email", "params", "phone"],
    "subject_types_supported" => ["public"],
    "token_endpoint" => "https://common.onelogin.com/oidc/2/token",
    "token_endpoint_auth_methods_supported" => [
      "client_secret_basic",
      "client_secret_post",
      "none"
    ],
    "userinfo_endpoint" => "https://common.onelogin.com/oidc/2/me",
    "userinfo_signing_alg_values_supported" => ["HS256", "RS256", "PS256"]
  },
  headers: [
    {"Date", "Sat, 12 Nov 2022 19:41:55 GMT"},
    {"Content-Type", "application/json; charset=utf-8"},
    {"Connection", "keep-alive"},
    {"vary", "Origin"},
    {"strict-transport-security", "max-age=63072000; includeSubDomains;"},
    {"x-content-type-options", "nosniff"},
    {"set-cookie", "ol_oidc_canary_115=false; path=/; domain=.onelogin.com; HttpOnly; Secure"},
    {"cache-control", "private"}
  ]
}
