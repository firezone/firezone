%{
  status_code: 200,
  body: %{
    "authorization_endpoint" => "https://accounts.google.com/o/oauth2/v2/auth",
    "claims_supported" => [
      "aud",
      "email",
      "email_verified",
      "exp",
      "family_name",
      "given_name",
      "iat",
      "iss",
      "locale",
      "name",
      "picture",
      "sub"
    ],
    "code_challenge_methods_supported" => ["plain", "S256"],
    "device_authorization_endpoint" => "https://oauth2.googleapis.com/device/code",
    "grant_types_supported" => [
      "authorization_code",
      "refresh_token",
      "urn:ietf:params:oauth:grant-type:device_code",
      "urn:ietf:params:oauth:grant-type:jwt-bearer"
    ],
    "id_token_signing_alg_values_supported" => ["RS256"],
    "issuer" => "https://accounts.google.com",
    "jwks_uri" => "https://www.googleapis.com/oauth2/v3/certs",
    "response_types_supported" => [
      "code",
      "token",
      "id_token",
      "code token",
      "code id_token",
      "token id_token",
      "code token id_token",
      "none"
    ],
    "revocation_endpoint" => "https://oauth2.googleapis.com/revoke",
    "scopes_supported" => ["openid", "email", "profile"],
    "subject_types_supported" => ["public"],
    "token_endpoint" => "https://oauth2.googleapis.com/token",
    "token_endpoint_auth_methods_supported" => ["client_secret_post", "client_secret_basic"],
    "userinfo_endpoint" => "https://openidconnect.googleapis.com/v1/userinfo"
  },
  headers: [
    {"Accept-Ranges", "bytes"},
    {"Vary", "Accept-Encoding"},
    {"Access-Control-Allow-Origin", "*"},
    {"Content-Security-Policy-Report-Only",
     "require-trusted-types-for 'script'; report-uri https://csp.withgoogle.com/csp/federated-signon-mpm-access"},
    {"Cross-Origin-Opener-Policy", "same-origin; report-to=\"federated-signon-mpm-access\""},
    {"Report-To",
     "{\"group\":\"federated-signon-mpm-access\",\"max_age\":2592000,\"endpoints\":[{\"url\":\"https://csp.withgoogle.com/csp/report-to/federated-signon-mpm-access\"}]}"},
    {"X-Content-Type-Options", "nosniff"},
    {"Server", "sffe"},
    {"X-XSS-Protection", "0"},
    {"Date", "Sat, 12 Nov 2022 19:03:58 GMT"},
    {"Expires", "Sat, 12 Nov 2022 20:03:58 GMT"},
    {"Cache-Control", "public, max-age=3600"},
    {"Age", "1698"},
    {"Last-Modified", "Thu, 16 Jan 2020 21:53:16 GMT"},
    {"Content-Type", "application/json"},
    {"Alt-Svc",
     "h3=\":443\"; ma=2592000,h3-29=\":443\"; ma=2592000,h3-Q050=\":443\"; ma=2592000,h3-Q046=\":443\"; ma=2592000,h3-Q043=\":443\"; ma=2592000,quic=\":443\"; ma=2592000; v=\"46,43\""}
  ]
}
