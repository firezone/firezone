%{
  status_code: 200,
  body: %{
    "keys" => [
      %{
        "alg" => "RS256",
        "e" => "AQAB",
        "kid" => "sljES1Bh0VMGwUpPfFunCVAzvLRdea7WluQfeV6zWTQ",
        "kty" => "RSA",
        "n" =>
          "7d7C4UL4HujzZesiEOtQUZcusHzBoUJVJXarHz0x9vMzQ1PYaGwivWJimnBHQXw6r1T05PQxOik9NnxvtPF7snPxVzDtDgrqzjd3WoYWmFiWrJz1vwebiioeFQKla7GkxfoE4cNFlIzi-i9y76zWwR3R3u0hUzHyY5XZcIBWnnInYKFACCNES7lqKu4qE3XTluJiP-WvDo79iFM67V2ZDowOWPLKoJQI0CA9l1Nkklaq32bjtMD9njl1Pl1KOKqZNyn1RzkmG0V15CYR959EEU7_Pl1LrrxGcgS-wafoyKILaJxEyeMWd3_SM0_anSAVvyUA46PYefcdEuURp-r4vQ",
        "use" => "sig"
      },
      %{
        "alg" => "RS256",
        "e" => "AQAB",
        "kid" => "TgT2Cxt-D-sVMlgTm3On7DLee8ljXgYhdzkrPkTc4sY",
        "kty" => "RSA",
        "n" =>
          "3VQaNpbZ67tiVkNqLF4j5skeys9D0Vzfu8NpOE8ZRVBmzLXa-FZ65cm6IGObMHhyDEBT4MTD3DLTRufVaiUbGcvrx5qee9eV_U3AwxSkRBEuHi-4HvUGkbvvXJpaoIHrNONZ_qLnL-GQm-kWTr3BaaRQ8lmMQjh3G4aCzzsFCpMT2HEe1GwCWDGTS_tDGt7oyueOtaPYFP3YLW7n8GW0-nVdiFxXYU0F-l9BF95YgYSut18r6xKk4EfHY4VNC6Y-qbldyEJ0iGdUT5sa07d7q6ocwDRO6iB07j65v43-A-H5vcew9N1JvFXXiJZ4Qn2UhzAGgUm6-Exr6fOko0W3zw",
        "use" => "sig"
      }
    ]
  },
  headers: [
    {"Date", "Sat, 12 Nov 2022 19:41:02 GMT"},
    {"Content-Type", "application/json"},
    {"Connection", "keep-alive"},
    {"Server", "nginx"},
    {"Public-Key-Pins-Report-Only",
     "pin-sha256=\"r5EfzZxQVvQpKo3AgYRaT7X2bDO/kj3ACwmxfdT2zt8=\"; pin-sha256=\"MaqlcUgk2mvY/RFSGeSwBRkI+rZ6/dxe/DuQfBT/vnQ=\"; pin-sha256=\"72G5IEvDEWn+EThf3qjR7/bQSWaS2ZSLqolhnO6iyJI=\"; pin-sha256=\"rrV6CLCCvqnk89gWibYT0JO6fNQ8cCit7GGoiVTjCOg=\"; max-age=60; report-uri=\"https://okta.report-uri.com/r/default/hpkp/reportOnly\""},
    {"x-xss-protection", "0"},
    {"p3p", "CP=\"HONK\""},
    {"content-security-policy",
     "default-src 'self' common.okta.com *.oktacdn.com; connect-src 'self' common.okta.com common-admin.okta.com *.oktacdn.com *.mixpanel.com *.mapbox.com app.pendo.io data.pendo.io pendo-static-5634101834153984.storage.googleapis.com pendo-static-5391521872216064.storage.googleapis.com common.kerberos.okta.com https://oinmanager.okta.com data:; script-src 'unsafe-inline' 'unsafe-eval' 'self' common.okta.com *.oktacdn.com; style-src 'unsafe-inline' 'self' common.okta.com *.oktacdn.com app.pendo.io cdn.pendo.io pendo-static-5634101834153984.storage.googleapis.com pendo-static-5391521872216064.storage.googleapis.com; frame-src 'self' common.okta.com common-admin.okta.com login.okta.com; img-src 'self' common.okta.com *.oktacdn.com *.tiles.mapbox.com *.mapbox.com app.pendo.io data.pendo.io cdn.pendo.io pendo-static-5634101834153984.storage.googleapis.com pendo-static-5391521872216064.storage.googleapis.com data: blob:; font-src 'self' common.okta.com data: *.oktacdn.com fonts.gstatic.com; frame-ancestors 'self'; report-uri https://oktacsp.report-uri.com/r/t/csp/enforce; report-to csp"},
    {"report-to",
     "{\"group\":\"csp\",\"max_age\":31536000,\"endpoints\":[{\"url\":\"https://oktacsp.report-uri.com/a/t/g\"}],\"include_subdomains\":true}"},
    {"expect-ct",
     "report-uri=\"https://oktaexpectct.report-uri.com/r/t/ct/reportOnly\", max-age=0"},
    {"cache-control", "max-age=3828277, must-revalidate"},
    {"expires", "Tue, 27 Dec 2022 03:05:39 GMT"},
    {"vary", "Origin"},
    {"x-content-type-options", "nosniff"},
    {"Strict-Transport-Security", "max-age=315360000; includeSubDomains"},
    {"X-Okta-Request-Id", "Y2_2zY7e1--88ktkBh3QSgAABkg"}
  ]
}
