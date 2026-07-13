%{
  status_code: 200,
  body: %{
    "authorization_endpoint" => "https://DOMAIN/oauth2/authorize",
    "id_token_signing_alg_values_supported" => [
      "RS256"
    ],
    "issuer" => "https://cognito-idp.REGION.amazonaws.com/REGION-CODE",
    "jwks_uri" => "https://cognito-idp.REGIONamazonaws.com/REGION-CODE/.well-known/jwks.json",
    "response_types_supported" => [
      "code",
      "token"
    ],
    "scopes_supported" => [
      "openid",
      "email",
      "phone",
      "profile"
    ],
    "subject_types_supported" => [
      "public"
    ],
    "token_endpoint" => "https://DOMAIN/oauth2/token",
    "token_endpoint_auth_methods_supported" => [
      "client_secret_basic",
      "client_secret_post"
    ],
    "userinfo_endpoint" => "https://DOMAIN/oauth2/userInfo"
  },
  headers: [
    {"Cache-Control", "max-age=86400, private"},
    {"Content-Type", "application/json; charset=utf-8"},
    {"Strict-Transport-Security", "max-age=31536000; includeSubDomains"},
    {"X-Content-Type-Options", "nosniff"},
    {"Access-Control-Allow-Origin", "*"},
    {"Access-Control-Allow-Methods", "GET, OPTIONS"},
    {"P3P", "CP=\"DSP CUR OTPi IND OTRi ONL FIN\""},
    {"x-ms-request-id", "d81e7f56-0451-4de4-a5c5-4af112d02001"},
    {"x-ms-ests-server", "2.1.14006.10 - NCUS ProdSlices"},
    {"X-XSS-Protection", "0"},
    {"Set-Cookie",
     "fpc=AuKLSwY1b3xLiInKP16p3E4; expires=Mon, 12-Dec-2022 19:36:30 GMT; path=/; secure; HttpOnly; SameSite=None"},
    {"Set-Cookie",
     "esctx=AQABAAAAAAD--DLA3VO7QrddgJg7Wevr2ALKzZMjPY-Tt7ffB-f_7y4AMTUR-4m-AQDAi0jJ1K4_N7dY0CZmKZdSweQPMgerZ-TeKnty43nfmYRZS2G39bKUZp5erQLwiB9rkuLis4_ee_cAZK7nh1pkqOh0_t52P9svf75Le0-ex8iyPVhexTbIROTaaYvo6Fl9DFqOtZOnmQplc6ken-ddUcLbnZRSKOTFdr03VB8oSt5gD2BBw2e5qeBuocgX0hS-W-FNbG0gAA; domain=.login.microsoftonline.com; path=/; secure; HttpOnly; SameSite=None"},
    {"Set-Cookie", "x-ms-gateway-slice=estsfd; path=/; secure; samesite=none; httponly"},
    {"Set-Cookie", "stsservicecookie=estsfd; path=/; secure; samesite=none; httponly"},
    {"Date", "Sat, 12 Nov 2022 19:36:29 GMT"}
  ]
}
