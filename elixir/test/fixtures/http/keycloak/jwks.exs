%{
  status_code: 200,
  body: %{
    "keys" => [
      %{
        "alg" => "RS256",
        "e" => "AQAB",
        "kid" => "nB0vgzwAcgJmjXwQZSzBMNkhoCaH4fvSwx5GC8Jq93c",
        "kty" => "RSA",
        "n" =>
          "zTxXhjNpLJy13O1sqVqZnlbqB0U618c9micjrs2f4NzdPT7rwLRnG3TYgTgMLDN8ERLffw-5RLZAOvTyryC0JLL2KhM-n6myrpJ5vjemp-l4f-RpcgtEVx1pe8ylKpj3SytZglMBC8ds8zFHMMf3y2HrqRUPfPHKCmdpRkLs7PhEBv8A3OTgCtp-g1YUB4s46vRun5AutMDogEXUMHdgkwPjTPTTRoUOiSulb5enhKIYj3xxUsK3yTT3Y6KkHuiHUvEfgX4l7ZsEAk1U1nA_-u86QlONRu4XVloiOHEU18zoFn6-xhER1j6lX000zTPf2FSbPpL2GdTPCN7Bj9t7rQ",
        "use" => "sig",
        "x5c" => [
          "MIICmzCCAYMCBgGEZ9w6QTANBgkqhkiG9w0BAQsFADARMQ8wDQYDVQQDDAZtYXN0ZXIwHhcNMjIxMTExMTgwMTM2WhcNMzIxMTExMTgwMzE2WjARMQ8wDQYDVQQDDAZtYXN0ZXIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDNPFeGM2ksnLXc7WypWpmeVuoHRTrXxz2aJyOuzZ/g3N09PuvAtGcbdNiBOAwsM3wREt9/D7lEtkA69PKvILQksvYqEz6fqbKuknm+N6an6Xh/5GlyC0RXHWl7zKUqmPdLK1mCUwELx2zzMUcwx/fLYeupFQ988coKZ2lGQuzs+EQG/wDc5OAK2n6DVhQHizjq9G6fkC60wOiARdQwd2CTA+NM9NNGhQ6JK6Vvl6eEohiPfHFSwrfJNPdjoqQe6IdS8R+BfiXtmwQCTVTWcD/67zpCU41G7hdWWiI4cRTXzOgWfr7GERHWPqVfTTTNM9/YVJs+kvYZ1M8I3sGP23utAgMBAAEwDQYJKoZIhvcNAQELBQADggEBALXouAkGrzu+5EpJLWwfQdtEYuEwK9VNheDdR2WqQDNwduk71hZWr5olNyhJz6ogMPOcNhQ33B9MssYqKtINrgxeSrO5k2QAYRYRq4BEJ+3Y9Yif9KNYV7IBXcNz4Z6fiFUnmIPoOU7dCb1Lt8sFLaa5EL1TVKQkMJ5nXLpMtTHywwEPvb/Aul1ssydfanpDW4/nCf512UpsnWetfiKw+IlTB7Rt5zMQ65RAimxz+hnY2+LF/XGnyNnPY6IPvX9suyt6u3EBM2xdXD+2UedJ8EbSvPTVo9nPfH59HmeIrIyJcw6/4xEjEVWN8oQEeYM3VOACORr2yK7zqbVpHQvOcz4="
        ],
        "x5t" => "JZ8jwBZn8nzU0Rl33DcHwZU_Qio",
        "x5t#S256" => "Y1XJpsaLUg3zbJVHyJij-zkNWmTbnM0y0Er1No84uTE"
      },
      %{
        "alg" => "RSA-OAEP",
        "e" => "AQAB",
        "kid" => "Q2O_f0Z7hVL1WUxKQbChyWK_FzQK-qRZh4Kg9mxxt_I",
        "kty" => "RSA",
        "n" =>
          "jY-UVOgGl1Io_aL8jS8__Y25tqsefFfjR-JIcd3fhMjHWfoomfPlz0YfUHC6UYF7dgQeQnFEQqjxonJLDh32EWKWuXvcEvfp5592tx6COsOku_jeypwNurj9iGkbx3bv8w7x-SVp5VLdCM0IXBASIVTdmOwVfMJChIrJbjsk_wgCyL2IzU4w5cb2NdodEf1cf5ROt25EhdVZhvFzcxsfHaqOvKPBtP1W3FXbuVAIkFuXxSZdAKOZHS00RX_YOFIcOr5USIof9lBF_fXo7UXY-gDz95MkwgnfbC6WnVk4v57fniytwCNwZO3Smt3WTDBhAeFp9d8Xn_sUhwoqcBw_9Q",
        "use" => "enc",
        "x5c" => [
          "MIICmzCCAYMCBgGEZ9w7jTANBgkqhkiG9w0BAQsFADARMQ8wDQYDVQQDDAZtYXN0ZXIwHhcNMjIxMTExMTgwMTM3WhcNMzIxMTExMTgwMzE3WjARMQ8wDQYDVQQDDAZtYXN0ZXIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCNj5RU6AaXUij9ovyNLz/9jbm2qx58V+NH4khx3d+EyMdZ+iiZ8+XPRh9QcLpRgXt2BB5CcURCqPGicksOHfYRYpa5e9wS9+nnn3a3HoI6w6S7+N7KnA26uP2IaRvHdu/zDvH5JWnlUt0IzQhcEBIhVN2Y7BV8wkKEisluOyT/CALIvYjNTjDlxvY12h0R/Vx/lE63bkSF1VmG8XNzGx8dqo68o8G0/VbcVdu5UAiQW5fFJl0Ao5kdLTRFf9g4Uhw6vlRIih/2UEX99ejtRdj6APP3kyTCCd9sLpadWTi/nt+eLK3AI3Bk7dKa3dZMMGEB4Wn13xef+xSHCipwHD/1AgMBAAEwDQYJKoZIhvcNAQELBQADggEBAD0e9ia9dDegLJFjRdAtfMZXj+6nVfSPNSPgMp4FBa1lx98EP5B3cEapVDRoAr/q3W3sI/88mzzXhrjhZEENep02JcKTZdZfyRoPShyVcPTLLUH0iiRYszTYj05iUpB9/wETN7rAjqpP+CV2a5uUL14K4sPZeWKOx3wCjEl7AdzlWCc65/XB1ZRVrRF0zJPcKQWb0YWgJb5cbj6/PNR3ZCHUw+PYi+i3/lJ3XObXmv/5+2PP0eXmeo9eTxoctKN947He95ugsOekzB2nU1XNcxDZzlMvKD2OiwkuG9SM+Uw7/sTBf/X/pHfzF9sKeq7B0vtHDunm+uBvRTZfbrDYKWk="
        ],
        "x5t" => "Y8cA4ZtbCbhVKJWC4swg2H3oBRE",
        "x5t#S256" => "pYO4_DMcglAP1G5HUhZxwlTo_nnDTpt7ORinPpUEiRc"
      }
    ]
  },
  headers: [
    {"Referrer-Policy", "no-referrer"},
    {"X-Frame-Options", "SAMEORIGIN"},
    {"Strict-Transport-Security", "max-age=31536000; includeSubDomains"},
    {"Cache-Control", "no-cache"},
    {"X-Content-Type-Options", "nosniff"},
    {"X-XSS-Protection", "1; mode=block"},
    {"Content-Type", "application/json"}
  ]
}
