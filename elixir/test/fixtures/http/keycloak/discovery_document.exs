%{
  status_code: 200,
  body: %{
    "frontchannel_logout_supported" => true,
    "userinfo_encryption_enc_values_supported" => [
      "A256GCM",
      "A192GCM",
      "A128GCM",
      "A128CBC-HS256",
      "A192CBC-HS384",
      "A256CBC-HS512"
    ],
    "authorization_encryption_alg_values_supported" => ["RSA-OAEP", "RSA-OAEP-256", "RSA1_5"],
    "scopes_supported" => [
      "openid",
      "phone",
      "acr",
      "microprofile-jwt",
      "email",
      "profile",
      "web-origins",
      "offline_access",
      "address",
      "roles"
    ],
    "introspection_endpoint" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/token/introspect",
    "token_endpoint" => "http://localhost:8080/realms/master/protocol/openid-connect/token",
    "backchannel_logout_session_supported" => true,
    "token_endpoint_auth_methods_supported" => [
      "private_key_jwt",
      "client_secret_basic",
      "client_secret_post",
      "tls_client_auth",
      "client_secret_jwt"
    ],
    "request_object_encryption_enc_values_supported" => [
      "A256GCM",
      "A192GCM",
      "A128GCM",
      "A128CBC-HS256",
      "A192CBC-HS384",
      "A256CBC-HS512"
    ],
    "require_pushed_authorization_requests" => false,
    "request_parameter_supported" => true,
    "revocation_endpoint_auth_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512"
    ],
    "device_authorization_endpoint" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/auth/device",
    "authorization_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512"
    ],
    "code_challenge_methods_supported" => ["plain", "S256"],
    "request_object_encryption_alg_values_supported" => ["RSA-OAEP", "RSA-OAEP-256", "RSA1_5"],
    "id_token_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512"
    ],
    "check_session_iframe" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/login-status-iframe.html",
    "issuer" => "http://localhost:8080/realms/master",
    "id_token_encryption_alg_values_supported" => ["RSA-OAEP", "RSA-OAEP-256", "RSA1_5"],
    "authorization_endpoint" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/auth",
    "userinfo_encryption_alg_values_supported" => ["RSA-OAEP", "RSA-OAEP-256", "RSA1_5"],
    "id_token_encryption_enc_values_supported" => [
      "A256GCM",
      "A192GCM",
      "A128GCM",
      "A128CBC-HS256",
      "A192CBC-HS384",
      "A256CBC-HS512"
    ],
    "backchannel_authentication_request_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "ES256",
      "RS256",
      "ES512",
      "PS256",
      "PS512",
      "RS512"
    ],
    "jwks_uri" => "http://localhost:8080/realms/master/protocol/openid-connect/certs",
    "backchannel_authentication_endpoint" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/ext/ciba/auth",
    "subject_types_supported" => ["public", "pairwise"],
    "authorization_encryption_enc_values_supported" => [
      "A256GCM",
      "A192GCM",
      "A128GCM",
      "A128CBC-HS256",
      "A192CBC-HS384",
      "A256CBC-HS512"
    ],
    "userinfo_endpoint" => "http://localhost:8080/realms/master/protocol/openid-connect/userinfo",
    "response_types_supported" => [
      "code",
      "none",
      "id_token",
      "token",
      "id_token token",
      "code id_token",
      "code token",
      "code id_token token"
    ],
    "mtls_endpoint_aliases" => %{
      "backchannel_authentication_endpoint" =>
        "http://localhost:8080/realms/master/protocol/openid-connect/ext/ciba/auth",
      "device_authorization_endpoint" =>
        "http://localhost:8080/realms/master/protocol/openid-connect/auth/device",
      "introspection_endpoint" =>
        "http://localhost:8080/realms/master/protocol/openid-connect/token/introspect",
      "pushed_authorization_request_endpoint" =>
        "http://localhost:8080/realms/master/protocol/openid-connect/ext/par/request",
      "registration_endpoint" =>
        "http://localhost:8080/realms/master/clients-registrations/openid-connect",
      "revocation_endpoint" =>
        "http://localhost:8080/realms/master/protocol/openid-connect/revoke",
      "token_endpoint" => "http://localhost:8080/realms/master/protocol/openid-connect/token",
      "userinfo_endpoint" =>
        "http://localhost:8080/realms/master/protocol/openid-connect/userinfo"
    },
    "backchannel_token_delivery_modes_supported" => ["poll", "ping"],
    "pushed_authorization_request_endpoint" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/ext/par/request",
    "grant_types_supported" => [
      "authorization_code",
      "implicit",
      "refresh_token",
      "password",
      "client_credentials",
      "urn:ietf:params:oauth:grant-type:device_code",
      "urn:openid:params:grant-type:ciba"
    ],
    "request_object_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512",
      "none"
    ],
    "tls_client_certificate_bound_access_tokens" => true,
    "userinfo_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512",
      "none"
    ],
    "claims_supported" => [
      "aud",
      "sub",
      "iss",
      "auth_time",
      "name",
      "given_name",
      "family_name",
      "preferred_username",
      "email",
      "acr"
    ],
    "introspection_endpoint_auth_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512"
    ],
    "revocation_endpoint_auth_methods_supported" => [
      "private_key_jwt",
      "client_secret_basic",
      "client_secret_post",
      "tls_client_auth",
      "client_secret_jwt"
    ],
    "token_endpoint_auth_signing_alg_values_supported" => [
      "PS384",
      "ES384",
      "RS384",
      "HS256",
      "HS512",
      "ES256",
      "RS256",
      "HS384",
      "ES512",
      "PS256",
      "PS512",
      "RS512"
    ],
    "acr_values_supported" => ["0", "1"],
    "registration_endpoint" =>
      "http://localhost:8080/realms/master/clients-registrations/openid-connect",
    "frontchannel_logout_session_supported" => true,
    "require_request_uri_registration" => true,
    "revocation_endpoint" => "http://localhost:8080/realms/master/protocol/openid-connect/revoke",
    "request_uri_parameter_supported" => true,
    "end_session_endpoint" =>
      "http://localhost:8080/realms/master/protocol/openid-connect/logout",
    "claims_parameter_supported" => true,
    "response_modes_supported" => [
      "query",
      "fragment",
      "form_post",
      "query.jwt",
      "fragment.jwt",
      "form_post.jwt",
      "jwt"
    ],
    "claim_types_supported" => ["normal"],
    "backchannel_logout_supported" => true,
    "introspection_endpoint_auth_methods_supported" => [
      "private_key_jwt",
      "client_secret_basic",
      "client_secret_post",
      "tls_client_auth",
      "client_secret_jwt"
    ]
  },
  headers: [
    {"Referrer-Policy", "no-referrer"},
    {"X-Frame-Options", "SAMEORIGIN"},
    {"Strict-Transport-Security", "max-age=31536000; includeSubDomains"},
    {"Cache-Control", "no-cache, must-revalidate, no-transform, no-store"},
    {"X-Content-Type-Options", "nosniff"},
    {"X-XSS-Protection", "1; mode=block"},
    {"Content-Type", "application/json"}
  ]
}
