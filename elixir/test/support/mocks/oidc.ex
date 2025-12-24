defmodule Web.Mocks.OIDC do
  @moduledoc """
  Mock server for OpenID Connect discovery and token endpoints.
  Uses Bypass to simulate an OIDC provider for testing.
  """

  def discovery_document_server do
    bypass = Bypass.open()
    endpoint = "http://localhost:#{bypass.port}"
    test_pid = self()

    Bypass.stub(bypass, "GET", "/.well-known/jwks.json", fn conn ->
      attrs = %{"keys" => [jwks()]}
      Plug.Conn.resp(conn, 200, JSON.encode!(attrs))
    end)

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})

      attrs = %{
        "issuer" => "#{endpoint}/",
        "authorization_endpoint" => "#{endpoint}/authorize",
        "token_endpoint" => "#{endpoint}/oauth/token",
        "client_authorization_endpoint" => "#{endpoint}/oauth/client/code",
        "userinfo_endpoint" => "#{endpoint}/userinfo",
        "mfa_challenge_endpoint" => "#{endpoint}/mfa/challenge",
        "jwks_uri" => "#{endpoint}/.well-known/jwks.json",
        "registration_endpoint" => "#{endpoint}/oidc/register",
        "revocation_endpoint" => "#{endpoint}/oauth/revoke",
        "end_session_endpoint" => "https://example.com",
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

      Plug.Conn.resp(conn, 200, JSON.encode!(attrs))
    end)

    bypass
  end

  def expect_refresh_token(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/oauth/token", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 200, JSON.encode!(attrs))
    end)

    bypass
  end

  def expect_refresh_token_failure(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/oauth/token", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 401, JSON.encode!(attrs))
    end)

    bypass
  end

  def expect_userinfo(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "GET", "/userinfo", fn conn ->
      attrs =
        Map.merge(
          %{
            "sub" => "353690423699814251281",
            "name" => "Ada Lovelace",
            "given_name" => "Ada",
            "family_name" => "Lovelace",
            "picture" =>
              "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg",
            "email" => "ada@example.com",
            "email_verified" => true,
            "locale" => "en"
          },
          attrs
        )

      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 200, JSON.encode!(attrs))
    end)

    bypass
  end

  def sign_openid_connect_token(claims) do
    {_alg, token} =
      jwks()
      |> JOSE.JWK.from()
      |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
      |> JOSE.JWS.compact()

    token
  end

  def jwks do
    %{
      "alg" => "RS256",
      "d" =>
        "X8TM24Zqbiha9geYYk_vZpANu16IadJLJLJ7ucTc3JaMbK8NCYNcHMoXKnNYPFxmq-UWAEIwh-2" <>
          "txOiOxuChVrblpfyE4SBJio1T0AUcCwmm8U6G-CsSHMMzWTt2dMTnArHjdyAIgOVRW5SVzhTT" <>
          "taf4JY-47S-fbcJ7g0hmBbVih5i1sE2fad4I4qFHT-YFU_pnUHbteR6GQuRW4r03Eon8Aje6a" <>
          "l2AxcYnfF8_cSOIOpkDgGavTtGYhhZPi2jZ7kPm6QGkNW5CyfEq5PGB6JOihw-XIFiiMzYgx0" <>
          "52rnzoqALoLheXrI0By4kgHSmcqOOmq7aiOff45rlSbpsR",
      "e" => "AQAB",
      "kid" => "example@firezone.dev",
      "kty" => "RSA",
      "n" =>
        "qlKll8no4lPYXNSuTTnacpFHiXwPOv_htCYvIXmiR7CWhiiOHQqj7KWXIW7TGxyoLVIyeRM4mwv" <>
          "kLI-UgsSMYdEKTT0j7Ydjrr0zCunPu5Gxr2yOmcRaszAzGxJL5DwpA0V40RqMlm5OuwdqS4To" <>
          "_p9LlLxzMF6RZe1OqslV5RZ4Y8FmrWq6BV98eIziEHL0IKdsAIrrOYkkcLDdQeMNuTp_yNB8X" <>
          "l2TdWSdsbRomrs2dCtCqZcXTsy2EXDceHvYhgAB33nh_w17WLrZQwMM-7kJk36Kk54jZd7i80" <>
          "AJf_s_plXn1mEh-L5IAL1vg3a9EOMFUl-lPiGqc3td_ykH",
      "use" => "sig"
    }
  end

  defp fetch_conn_params(conn) do
    opts = Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)

    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Parsers.call(opts)
  end
end
