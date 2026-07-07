defmodule OpenIDConnect.DocumentTest do
  use ExUnit.Case, async: true
  import OpenIDConnect.Fixtures
  import OpenIDConnect.Document

  describe "fetch_document/1" do
    test "returns error when URL is nil" do
      assert fetch_document(nil) == {:error, :invalid_discovery_document_uri}
    end

    test "returns valid document from a given url" do
      {test_name, uri} = start_fixture("auth0")

      assert {:ok, document} = fetch_document(uri, req_test_options(test_name))

      assert %OpenIDConnect.Document{
               authorization_endpoint: "https://common.auth0.com/authorize",
               claims_supported: [
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
               end_session_endpoint: nil,
               expires_at: expires_at,
               jwks: %JOSE.JWK{},
               raw: _json,
               response_types_supported: [
                 "code",
                 "token",
                 "id_token",
                 "code token",
                 "code id_token",
                 "id_token token",
                 "code id_token token"
               ],
               token_endpoint: "https://common.auth0.com/oauth/token"
             } = document

      # The fixture has Cache-Control: max-age=15, so expires_at should be ~15 seconds from now
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 13..17
    end

    test "supports all gateway providers" do
      for provider <- [
            "auth0",
            "azure",
            "google",
            "keycloak",
            "okta",
            "onelogin",
            "vault",
            "cognito"
          ] do
        {test_name, uri} = start_fixture(provider)
        assert {:ok, document} = fetch_document(uri, req_test_options(test_name))
        assert not is_nil(document.jwks)
      end
    end

    test "caches the document" do
      {test_name, uri} = start_fixture("auth0")

      assert {:ok, document} = fetch_document(uri, req_test_options(test_name))
      assert {:ok, ^document} = fetch_document(uri, req_test_options(test_name))
    end

    test "returns error when JSWKS is invalid" do
      invalid_jwks = %{
        "keys" => [
          %{
            "kid" => "1234example=",
            "alg" => "RS256",
            "kty" => "RSA",
            "e" => "AQAB",
            "n" => "1234567890",
            "use" => "sig"
          },
          %{
            "kid" => "5678example=",
            "alg" => "RS256",
            "kty" => "RSA",
            "e" => "AQAB",
            "n" => "987654321",
            "use" => "sig"
          }
        ]
      }

      {test_name, uri} = start_fixture("auth0", %{"jwks" => invalid_jwks})

      assert fetch_document(uri, req_test_options(test_name)) ==
               {:error, :invalid_jwks_certificates}
    end

    test "handles non 2XX response codes" do
      test_name = unique_test_name()

      Req.Test.stub(test_name, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
      end)

      uri = "http://#{test_name}/.well-known/discovery-document.json"

      assert fetch_document(uri, req_test_options(test_name)) == {:error, {401, "{}"}}
    end

    test "ignores documents larger than 1MB" do
      test_name = unique_test_name()

      # Just over 1MB (1MB + 1KB) is enough to trigger the size limit
      large_document = String.duplicate("A", 1024 * 1024 + 1024)

      Req.Test.stub(test_name, fn conn ->
        Req.Test.text(conn, large_document)
      end)

      uri = "http://#{test_name}/.well-known/discovery-document.json"

      assert fetch_document(uri, req_test_options(test_name)) ==
               {:error, :discovery_document_is_too_large}
    end

    test "handles invalid responses" do
      test_name = unique_test_name()

      Req.Test.stub(test_name, fn conn ->
        Req.Test.json(conn, %{})
      end)

      uri = "http://#{test_name}/.well-known/discovery-document.json"

      assert fetch_document(uri, req_test_options(test_name)) == {:error, :invalid_document}
    end

    test "handles response errors" do
      test_name = unique_test_name()
      uri = "http://#{test_name}/.well-known/discovery-document.json"

      Req.Test.stub(test_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert fetch_document(uri, req_test_options(test_name)) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end

    test "takes expiration date from Cache-Control headers of the discovery document" do
      test_name = unique_test_name()
      endpoint = "http://#{test_name}/"
      provider = "vault"

      Req.Test.stub(test_name, fn conn ->
        case conn.request_path do
          "/.well-known/jwks.json" ->
            {status_code, body, headers} = load_fixture(provider, "jwks")
            send_response(conn, status_code, body, headers)

          "/.well-known/discovery-document.json" ->
            {status_code, body, headers} = load_fixture(provider, "discovery_document")
            body = Map.merge(body, %{"jwks_uri" => "#{endpoint}.well-known/jwks.json"})

            headers =
              for {k, v} <- headers,
                  k = String.downcase(k),
                  k not in ["cache-control", "age"] do
                {k, v}
              end

            headers = headers ++ [{"cache-control", "max-age=300"}]
            send_response(conn, status_code, body, headers)
        end
      end)

      uri = "#{endpoint}.well-known/discovery-document.json"

      assert {:ok, document} = fetch_document(uri, req_test_options(test_name))
      expected_expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
      assert DateTime.diff(document.expires_at, expected_expires_at) in -3..3
    end

    test "takes expiration date from Cache-Control and Age headers of the discovery document" do
      test_name = unique_test_name()
      endpoint = "http://#{test_name}/"
      provider = "vault"

      Req.Test.stub(test_name, fn conn ->
        case conn.request_path do
          "/.well-known/jwks.json" ->
            {status_code, body, headers} = load_fixture(provider, "jwks")
            send_response(conn, status_code, body, headers)

          "/.well-known/discovery-document.json" ->
            {status_code, body, headers} = load_fixture(provider, "discovery_document")
            body = Map.merge(body, %{"jwks_uri" => "#{endpoint}.well-known/jwks.json"})

            headers =
              for {k, v} <- headers,
                  k = String.downcase(k),
                  k not in ["cache-control", "age"] do
                {k, v}
              end

            headers = headers ++ [{"cache-control", "max-age=300"}, {"age", "100"}]
            send_response(conn, status_code, body, headers)
        end
      end)

      uri = "#{endpoint}.well-known/discovery-document.json"

      assert {:ok, document} = fetch_document(uri, req_test_options(test_name))
      expected_expires_at = DateTime.add(DateTime.utc_now(), 300 - 100, :second)
      assert DateTime.diff(document.expires_at, expected_expires_at) in -3..3
    end

    test "takes expiration date from Cache-Control and Age headers of the jwks document" do
      test_name = unique_test_name()
      endpoint = "http://#{test_name}/"
      provider = "vault"

      Req.Test.stub(test_name, fn conn ->
        case conn.request_path do
          "/.well-known/jwks.json" ->
            {status_code, body, headers} = load_fixture(provider, "jwks")

            headers =
              for {k, v} <- headers,
                  k = String.downcase(k),
                  k not in ["cache-control", "age"] do
                {k, v}
              end

            headers = headers ++ [{"cache-control", "max-age=300"}, {"age", "100"}]
            send_response(conn, status_code, body, headers)

          "/.well-known/discovery-document.json" ->
            {status_code, body, headers} = load_fixture(provider, "discovery_document")
            body = Map.merge(body, %{"jwks_uri" => "#{endpoint}.well-known/jwks.json"})
            send_response(conn, status_code, body, headers)
        end
      end)

      uri = "#{endpoint}.well-known/discovery-document.json"

      assert {:ok, document} = fetch_document(uri, req_test_options(test_name))
      expected_expires_at = DateTime.add(DateTime.utc_now(), 300 - 100, :second)
      assert DateTime.diff(document.expires_at, expected_expires_at) in -3..3
    end
  end
end
