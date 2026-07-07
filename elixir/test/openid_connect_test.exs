defmodule OpenIDConnectTest do
  use ExUnit.Case, async: true
  import OpenIDConnect.Fixtures
  import OpenIDConnect

  @redirect_uri "https://localhost/redirect_uri"

  @config %{
    discovery_document_uri: nil,
    client_id: "CLIENT_ID",
    client_secret: "CLIENT_SECRET",
    response_type: "code id_token token",
    scope: "openid email profile",
    req_opts: []
  }

  describe "authorization_uri/3" do
    test "generates authorization url with scope and response_type as binaries" do
      {test_name, uri} = start_fixture("google")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:ok, url} = authorization_uri(config, @redirect_uri)
      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=CLIENT_ID"
      assert url =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
      assert url =~ "response_type=code+id_token+token"
      assert url =~ "scope=openid+email+profile"
    end

    test "generates authorization url with scope as enum" do
      {test_name, uri} = start_fixture("google")

      config = %{
        @config
        | discovery_document_uri: uri,
          scope: ["openid", "email", "profile"],
          req_opts: req_test_options(test_name)
      }

      assert {:ok, url} = authorization_uri(config, @redirect_uri)
      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=CLIENT_ID"
      assert url =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
      assert url =~ "response_type=code+id_token+token"
      assert url =~ "scope=openid+email+profile"
    end

    test "generates authorization url with response_type as enum" do
      {test_name, uri} = start_fixture("google")

      config = %{
        @config
        | discovery_document_uri: uri,
          response_type: ["code", "id_token", "token"],
          req_opts: req_test_options(test_name)
      }

      assert {:ok, url} = authorization_uri(config, @redirect_uri)

      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=CLIENT_ID"
      assert url =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
      assert url =~ "response_type=code+id_token+token"
      assert url =~ "scope=openid+email+profile"
    end

    test "returns error on empty scope" do
      {test_name, uri} = start_fixture("google")

      config = %{
        @config
        | discovery_document_uri: uri,
          scope: nil,
          req_opts: req_test_options(test_name)
      }

      assert authorization_uri(config, @redirect_uri) == {:error, :invalid_scope}

      config = %{
        @config
        | discovery_document_uri: uri,
          scope: "",
          req_opts: req_test_options(test_name)
      }

      assert authorization_uri(config, @redirect_uri) == {:error, :invalid_scope}

      config = %{
        @config
        | discovery_document_uri: uri,
          scope: [],
          req_opts: req_test_options(test_name)
      }

      assert authorization_uri(config, @redirect_uri) == {:error, :invalid_scope}
    end

    test "returns error on empty response_type" do
      {test_name, uri} = start_fixture("google")

      config = %{
        @config
        | discovery_document_uri: uri,
          response_type: nil,
          req_opts: req_test_options(test_name)
      }

      assert authorization_uri(config, @redirect_uri) == {:error, :invalid_response_type}

      config = %{
        @config
        | discovery_document_uri: uri,
          response_type: "",
          req_opts: req_test_options(test_name)
      }

      assert authorization_uri(config, @redirect_uri) == {:error, :invalid_response_type}

      config = %{
        @config
        | discovery_document_uri: uri,
          response_type: [],
          req_opts: req_test_options(test_name)
      }

      assert authorization_uri(config, @redirect_uri) == {:error, :invalid_response_type}
    end

    test "adds optional params" do
      {test_name, uri} = start_fixture("google")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:ok, url} = authorization_uri(config, @redirect_uri, %{"state" => "foo"})

      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=CLIENT_ID"
      assert url =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
      assert url =~ "response_type=code+id_token+token"
      assert url =~ "scope=openid+email+profile"
      assert url =~ "state=foo"
    end

    test "params can override default values" do
      {test_name, uri} = start_fixture("google")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:ok, url} = authorization_uri(config, @redirect_uri, %{client_id: "foo"})
      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=foo"
      assert url =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
      assert url =~ "response_type=code+id_token+token"
      assert url =~ "scope=openid+email+profile"
    end

    test "returns error when document is not available" do
      test_name = unique_test_name()
      uri = "http://#{test_name}/.well-known/discovery-document.json"

      Req.Test.stub(test_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert authorization_uri(config, @redirect_uri, %{client_id: "foo"}) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end
  end

  describe "end_session_uri/2" do
    test "returns error when provider doesn't specify end_session_endpoint" do
      {test_name, uri} = start_fixture("google")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert end_session_uri(config) == {:error, :endpoint_not_set}
    end

    test "generates authorization url" do
      {test_name, uri} = start_fixture("okta")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert end_session_uri(config) ==
               {:ok, "https://common.okta.com/oauth2/v1/logout?client_id=CLIENT_ID"}
    end

    test "adds optional params" do
      {test_name, uri} = start_fixture("okta")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert end_session_uri(config, %{"state" => "foo"}) ==
               {:ok, "https://common.okta.com/oauth2/v1/logout?client_id=CLIENT_ID&state=foo"}
    end

    test "params can override default values" do
      {test_name, uri} = start_fixture("okta")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert end_session_uri(config, %{client_id: "foo"}) ==
               {:ok, "https://common.okta.com/oauth2/v1/logout?client_id=foo"}
    end

    test "returns error when document is not available" do
      test_name = unique_test_name()
      uri = "http://#{test_name}/.well-known/discovery-document.json"

      Req.Test.stub(test_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert end_session_uri(config, %{client_id: "foo"}) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end
  end

  describe "fetch_tokens/2" do
    test "fetches the token from OAuth token endpoint" do
      test_pid = self()

      token_response_attrs = %{
        "access_token" => "ACCESS_TOKEN",
        "id_token" => "ID_TOKEN",
        "refresh_token" => "REFRESH_TOKEN"
      }

      token_handler = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, body})
        Req.Test.json(conn, token_response_attrs)
      end

      {test_name, uri} =
        start_fixture_with_routes("google", %{}, %{{"POST", "/token"} => token_handler})

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      params = %{
        grant_type: "authorization_code",
        redirect_uri: @redirect_uri,
        code: "1234",
        id_token: "abcd"
      }

      assert fetch_tokens(config, params) == {:ok, token_response_attrs}

      assert_receive {:req, body}
      assert body =~ "client_id=CLIENT_ID"
      assert body =~ "client_secret=CLIENT_SECRET"
      assert body =~ "code=1234"
      assert body =~ "grant_type=authorization_code"
      assert body =~ "id_token=abcd"
      assert body =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
    end

    test "allows to override the default params" do
      test_pid = self()

      token_response_attrs = %{
        "access_token" => "ACCESS_TOKEN",
        "id_token" => "ID_TOKEN",
        "refresh_token" => "REFRESH_TOKEN"
      }

      token_handler = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, body})
        Req.Test.json(conn, token_response_attrs)
      end

      {test_name, uri} =
        start_fixture_with_routes("google", %{}, %{{"POST", "/token"} => token_handler})

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      fetch_tokens(config, %{
        client_id: "foo",
        grant_type: "authorization_code",
        redirect_uri: @redirect_uri
      })

      assert_receive {:req, body}
      assert body =~ "client_id=foo"
      assert body =~ "client_secret=CLIENT_SECRET"
      assert body =~ "grant_type=authorization_code"
      assert body =~ "redirect_uri=#{URI.encode_www_form(@redirect_uri)}"
    end

    test "allows to use refresh_token grant type" do
      test_pid = self()

      token_response_attrs = %{
        "access_token" => "ACCESS_TOKEN",
        "id_token" => "ID_TOKEN",
        "refresh_token" => "REFRESH_TOKEN"
      }

      token_handler = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, body})
        Req.Test.json(conn, token_response_attrs)
      end

      {test_name, uri} =
        start_fixture_with_routes("google", %{}, %{{"POST", "/token"} => token_handler})

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      fetch_tokens(config, %{grant_type: "refresh_token", refresh_token: "foo"})

      assert_receive {:req, body}
      assert body =~ "client_id=CLIENT_ID"
      assert body =~ "client_secret=CLIENT_SECRET"
      assert body =~ "grant_type=refresh_token"
      assert body =~ "refresh_token=foo"
    end

    test "returns error when token endpoint is not available" do
      error_handler = fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end

      {test_name, uri} =
        start_fixture_with_routes("google", %{}, %{{"POST", "/token"} => error_handler})

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}
      params = %{grant_type: "authorization_code", redirect_uri: @redirect_uri}

      assert fetch_tokens(config, params) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end

    test "returns error when token endpoint responds with non 2XX status code" do
      error_handler = fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "unauthorized"})
      end

      {test_name, uri} =
        start_fixture_with_routes("google", %{}, %{{"POST", "/token"} => error_handler})

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert fetch_tokens(config, %{}) ==
               {:error, {401, %{"error" => "unauthorized"}}}
    end

    test "returns error when token endpoint responds with invalid code" do
      google_error_handler = fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{
          "error" => "invalid_client",
          "error_description" => "The OAuth client was not found."
        })
      end

      {test_name, uri} =
        start_fixture_with_routes("google", %{}, %{{"POST", "/token"} => google_error_handler})

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:error, {401, resp}} =
               fetch_tokens(config, %{
                 grant_type: "authorization_code",
                 redirect_uri: @redirect_uri,
                 code: "foo"
               })

      assert resp == %{
               "error" => "invalid_client",
               "error_description" => "The OAuth client was not found."
             }

      for provider <- ["auth0", "okta", "onelogin"] do
        error_handler = fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "invalid_grant"})
        end

        {test_name, uri} =
          start_fixture_with_routes(provider, %{}, %{{"POST", "/token"} => error_handler})

        config = %{
          @config
          | discovery_document_uri: uri,
            req_opts: req_test_options(test_name)
        }

        assert {:error, {status, _resp}} =
                 fetch_tokens(config, %{
                   grant_type: "authorization_code",
                   redirect_uri: @redirect_uri,
                   code: "foo"
                 })

        assert status in 400..499
      end
    end

    test "returns error when document is not available" do
      test_name = unique_test_name()
      uri = "http://#{test_name}/.well-known/discovery-document.json"

      Req.Test.stub(test_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      params = %{
        grant_type: "authorization_code",
        redirect_uri: @redirect_uri,
        code: "foo"
      }

      assert fetch_tokens(config, params) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end
  end

  describe "verify/2" do
    test "returns error when token has invalid format" do
      assert verify(@config, "foo") ==
               {:error, {:invalid_jwt, "invalid token format"}}
    end

    test "returns error when encoded token is not a JSON map" do
      token =
        ["fail", "fail", "fail"]
        |> Enum.map_join(".", fn header -> Base.encode64(header) end)

      assert verify(@config, token) ==
               {:error, {:invalid_jwt, "token header JSON is incomplete"}}
    end

    test "returns error when token header contains invalid JSON byte" do
      # Create a token where the header contains an invalid byte (0xFF is not valid JSON)
      header = Base.url_encode64(<<0xFF>>, padding: false)
      claims = Base.url_encode64(~s({"foo":"bar"}), padding: false)
      signature = Base.url_encode64("sig", padding: false)
      token = "#{header}.#{claims}.#{signature}"

      assert verify(@config, token) ==
               {:error, {:invalid_jwt, "token header contains invalid JSON"}}
    end

    test "returns error when token header contains invalid UTF-8 escape sequence" do
      # Create a token where the header contains an invalid escape sequence
      # \uXXXX is an invalid Unicode escape sequence (not valid hex)
      header = Base.url_encode64(~s({"alg":"\\uXXXX"}), padding: false)
      claims = Base.url_encode64(~s({"foo":"bar"}), padding: false)
      signature = Base.url_encode64("sig", padding: false)
      token = "#{header}.#{claims}.#{signature}"

      assert verify(@config, token) ==
               {:error, {:invalid_jwt, "token header contains invalid UTF-8 escape sequence"}}
    end

    test "returns error when encoded token is doesn't have valid 'alg'" do
      token =
        ["{}", "{}", "{}"]
        |> Enum.map_join(".", fn header -> Base.encode64(header) end)

      assert verify(@config, token) ==
               {:error, {:invalid_jwt, "no `alg` found in token"}}
    end

    test "returns error when token is valid but invalid for a provider" do
      {test_name, uri} = start_fixture("okta")
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}
      {jwk, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")

      claims = %{"email" => "brian@example.com"}

      {_alg, token} =
        jwk
        |> JOSE.JWK.from()
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:error, {:invalid_jwt, "verification failed"}}
    end

    test "returns claims when encoded token is valid" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:ok, claims}
    end

    test "returns claims when aud claim is a list containing client_id" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix(),
        "aud" => ["other-app", config.client_id, "another-app"]
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:ok, claims}
    end

    test "returns claims when encoded token is valid using multiple keys" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwks.exs")

      jwk =
        jwks
        |> Map.fetch!("keys")
        |> List.first()
        |> JOSE.JWK.from()

      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:ok, claims}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(-29, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:ok, claims}
    end

    # This test is only needed due to the following issue in erlang-jose:
    # https://github.com/potatosalad/erlang-jose/issues/177
    #
    # Prior to the code changes that prompted adding this test, if an EdDSA
    # key was present in the JWKS prior to the key that signed the JWT
    # the `verify_signature` function, would return an {:error, reason} and would
    # cause the function to return early without finding the appropriate signing key.

    test "returns claims when JWKS contains EdDSA key prior to signing key" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwks_eddsa.exs")
      {jwk, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwks})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:ok, claims}
    end

    test "returns error when token is expired" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(-31, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) ==
               {:error, {:invalid_jwt, "invalid exp claim: token has expired"}}
    end

    test "returns error when token expiration is not set" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:error, {:invalid_jwt, "invalid exp claim: missing"}}
    end

    test "returns error when token expiration is not an integer" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => "not-an-integer",
        "aud" => config.client_id
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:error, {:invalid_jwt, "invalid exp claim: is invalid"}}
    end

    test "returns error when aud claim is for another application" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.to_unix(),
        "aud" => "foo"
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) ==
               {:error,
                {:invalid_jwt, "invalid aud claim: token is intended for another application"}}
    end

    test "returns error when aud claim is not set" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.to_unix()
      }

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:error, {:invalid_jwt, "invalid aud claim: missing"}}
    end

    test "returns error when token is altered" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} = start_fixture("vault", %{"jwks" => jwk_pubkey})
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{"email" => "brian@example.com"}

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token <> ":)") == {:error, {:invalid_jwt, "verification failed"}}
    end

    test "clears the cache and retries when verification fails (signing key rotation)" do
      # IdP rotates signing key; cached JWKS holds "old-kid", token carries "new-kid".
      {old_raw, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      {_, old_pubkey} = old_raw |> JOSE.JWK.from() |> JOSE.JWK.to_public_map()
      old_pubkey = Map.put(old_pubkey, "kid", "old-kid")

      new_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      {_, new_pubkey} = JOSE.JWK.to_public_map(new_jwk)
      new_pubkey = Map.put(new_pubkey, "kid", "new-kid")

      {test_name, uri, jwks_calls} = stub_with_rotating_jwks(old_pubkey, new_pubkey)
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      # Prime the cache so `verify/2`'s pre-call peek sees a cached doc.
      assert {:ok, _} = OpenIDConnect.Document.fetch_document(uri, config.req_opts)
      assert :counters.get(jwks_calls, 1) == 1

      claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, token} =
        new_jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256", "kid" => "new-kid"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:ok, claims}
      # 1 prime + 1 refresh on unknown kid.
      assert :counters.get(jwks_calls, 1) == 2
    end

    test "does not refresh the cache for tampered tokens whose kid is known" do
      # Known-kid failures are signature mismatches, not rotations — must not evict (DoS guard).
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)
      jwk_pubkey = Map.put(jwk_pubkey, "kid", "known-kid")

      {test_name, uri, jwks_calls} = stub_with_rotating_jwks(jwk_pubkey, jwk_pubkey)
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:ok, _} = OpenIDConnect.Document.fetch_document(uri, config.req_opts)
      assert :counters.get(jwks_calls, 1) == 1

      claims = %{"email" => "brian@example.com"}

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256", "kid" => "known-kid"})
        |> JOSE.JWS.compact()

      assert verify(config, token <> ":)") == {:error, {:invalid_jwt, "verification failed"}}
      # No refresh — the prime fetch is still the only JWKS call.
      assert :counters.get(jwks_calls, 1) == 1
    end

    test "does not refresh the cache when the document was not previously cached" do
      # Cold cache = JWKS already fresh; retry would just amplify upstream load.
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)
      jwk_pubkey = Map.put(jwk_pubkey, "kid", "known-kid")

      {test_name, uri, jwks_calls} = stub_with_rotating_jwks(jwk_pubkey, jwk_pubkey)
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      stranger_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      claims = %{"email" => "brian@example.com"}

      {_alg, token} =
        stranger_jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256", "kid" => "unknown-kid"})
        |> JOSE.JWS.compact()

      assert verify(config, token) == {:error, {:invalid_jwt, "verification failed"}}
      assert :counters.get(jwks_calls, 1) == 1
    end

    test "preserves cached JWKS when refresh fails after unknown-kid verification" do
      # If the refetch errors (provider unreachable), the old cached JWKS must
      # stay intact so legitimately-signed tokens still verify.
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)
      jwk_pubkey = Map.put(jwk_pubkey, "kid", "cached-kid")

      test_name = unique_test_name()
      endpoint = "http://#{test_name}/"
      uri = "#{endpoint}.well-known/discovery-document.json"
      jwks_calls = :counters.new(1, [])

      {disc_status, disc_body, disc_headers} =
        OpenIDConnect.Fixtures.load_fixture("vault", "discovery_document")

      disc_body = Map.put(disc_body, "jwks_uri", "#{endpoint}.well-known/jwks.json")

      {jwks_status, _, jwks_headers} = OpenIDConnect.Fixtures.load_fixture("vault", "jwks")
      jwks_body = %{"keys" => [jwk_pubkey]}

      Req.Test.stub(test_name, fn conn ->
        case conn.request_path do
          "/.well-known/discovery-document.json" ->
            OpenIDConnect.Fixtures.send_response(conn, disc_status, disc_body, disc_headers)

          "/.well-known/jwks.json" ->
            :counters.add(jwks_calls, 1, 1)

            if :counters.get(jwks_calls, 1) == 1 do
              OpenIDConnect.Fixtures.send_response(conn, jwks_status, jwks_body, jwks_headers)
            else
              Req.Test.transport_error(conn, :econnrefused)
            end
        end
      end)

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:ok, _} = OpenIDConnect.Document.fetch_document(uri, config.req_opts)
      assert :counters.get(jwks_calls, 1) == 1

      stranger_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      bad_claims = %{"email" => "brian@example.com"}

      {_alg, bad_token} =
        stranger_jwk
        |> JOSE.JWS.sign(JSON.encode!(bad_claims), %{"alg" => "RS256", "kid" => "unknown-kid"})
        |> JOSE.JWS.compact()

      # Refresh is attempted and fails — original verification error is returned.
      assert verify(config, bad_token) == {:error, {:invalid_jwt, "verification failed"}}
      assert :counters.get(jwks_calls, 1) == 2

      # Cached JWKS is still usable — a token signed by the cached key verifies.
      legit_claims = %{
        "email" => "brian@example.com",
        "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix(),
        "aud" => config.client_id
      }

      {_alg, legit_token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(legit_claims), %{"alg" => "RS256", "kid" => "cached-kid"})
        |> JOSE.JWS.compact()

      assert verify(config, legit_token) == {:ok, legit_claims}
      # No additional JWKS fetch — verification hit the preserved cache.
      assert :counters.get(jwks_calls, 1) == 2
    end

    test "throttles JWKS refreshes per URI to mitigate DoS via unknown-kid spam" do
      # Sustained unknown-kid traffic must not translate 1:1 into JWKS refetches —
      # the per-URI cooldown caps refreshes within the configured window.
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)
      jwk_pubkey = Map.put(jwk_pubkey, "kid", "known-kid")

      {test_name, uri, jwks_calls} = stub_with_rotating_jwks(jwk_pubkey, jwk_pubkey)
      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      assert {:ok, _} = OpenIDConnect.Document.fetch_document(uri, config.req_opts)
      assert :counters.get(jwks_calls, 1) == 1

      stranger_jwk = JOSE.JWK.generate_key({:rsa, 2048})

      for kid <- ["unknown-1", "unknown-2", "unknown-3"] do
        {_alg, token} =
          stranger_jwk
          |> JOSE.JWS.sign(JSON.encode!(%{"email" => "x"}), %{"alg" => "RS256", "kid" => kid})
          |> JOSE.JWS.compact()

        assert verify(config, token) == {:error, {:invalid_jwt, "verification failed"}}
      end

      # 1 prime + 1 refresh (first unknown kid); the next two are inside the cooldown.
      assert :counters.get(jwks_calls, 1) == 2
    end

    test "returns error when document is not available" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")

      test_name = unique_test_name()
      uri = "http://#{test_name}/.well-known/discovery-document.json"

      Req.Test.stub(test_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{"email" => "brian@example.com"}

      {_alg, token} =
        jwks
        |> JOSE.JWK.from()
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert verify(config, token) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end
  end

  describe "fetch_userinfo/2" do
    test "returns user info using endpoint from discovery document" do
      test_pid = self()

      {
        userinfo_status_code,
        userinfo_response_attrs,
        _userinfo_response_headers
      } = load_fixture("google", "userinfo")

      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      userinfo_handler = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, body, conn.req_headers})

        conn
        |> Plug.Conn.put_status(userinfo_status_code)
        |> Req.Test.json(userinfo_response_attrs)
      end

      {test_name, uri} =
        start_fixture_with_routes("vault", %{"jwks" => jwk_pubkey}, %{
          {"GET", "/userinfo"} => userinfo_handler
        })

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{"email" => userinfo_response_attrs["email"]}

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert {:ok, userinfo} = fetch_userinfo(config, token)

      assert userinfo == userinfo_response_attrs

      assert_receive {:req, "", headers}
      assert {"authorization", "Bearer #{token}"} in headers
    end

    test "returns error when userinfo endpoint is not defined by discovery document" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      {test_name, uri} =
        start_fixture("vault", %{
          "jwks" => jwk_pubkey,
          "userinfo_endpoint" => nil
        })

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{"email" => "foo@john.com"}

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert fetch_userinfo(config, token) == {:error, :userinfo_endpoint_is_not_implemented}
    end

    test "returns error when userinfo endpoint is not available" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      error_handler = fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end

      {test_name, uri} =
        start_fixture_with_routes("vault", %{"jwks" => jwk_pubkey}, %{
          {"GET", "/userinfo"} => error_handler
        })

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{"email" => "foo@john.com"}

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert fetch_userinfo(config, token) ==
               {:error, %Req.TransportError{reason: :econnrefused}}
    end

    test "returns error when userinfo endpoint returns non-2XX status" do
      {jwks, []} = Code.eval_file("test/fixtures/jwks/jwk.exs")
      jwk = JOSE.JWK.from(jwks)
      {_, jwk_pubkey} = JOSE.JWK.to_public_map(jwk)

      error_handler = fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
      end

      {test_name, uri} =
        start_fixture_with_routes("vault", %{"jwks" => jwk_pubkey}, %{
          {"GET", "/userinfo"} => error_handler
        })

      config = %{@config | discovery_document_uri: uri, req_opts: req_test_options(test_name)}

      claims = %{"email" => "foo@john.com"}

      {_alg, token} =
        jwk
        |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      assert fetch_userinfo(config, token) == {:error, {401, "Unauthorized"}}
    end
  end

  # Stubs JWKS endpoint to serve `first_pubkey` on call 1 and `subsequent_pubkey` after.
  defp stub_with_rotating_jwks(first_pubkey, subsequent_pubkey) do
    test_name = unique_test_name()
    endpoint = "http://#{test_name}/"
    uri = "#{endpoint}.well-known/discovery-document.json"
    jwks_calls = :counters.new(1, [])

    discovery = load_discovery_fixture(endpoint)
    jwks = load_jwks_fixture()

    Req.Test.stub(test_name, fn conn ->
      handle_rotating_request(conn, discovery, jwks, first_pubkey, subsequent_pubkey, jwks_calls)
    end)

    {test_name, uri, jwks_calls}
  end

  defp load_discovery_fixture(endpoint) do
    {status, body, headers} =
      OpenIDConnect.Fixtures.load_fixture("vault", "discovery_document")

    body = Map.put(body, "jwks_uri", "#{endpoint}.well-known/jwks.json")
    {status, body, headers}
  end

  defp load_jwks_fixture do
    {status, _body, headers} = OpenIDConnect.Fixtures.load_fixture("vault", "jwks")
    {status, headers}
  end

  defp handle_rotating_request(
         %{request_path: "/.well-known/discovery-document.json"} = conn,
         {status, body, headers},
         _jwks,
         _first,
         _subsequent,
         _calls
       ) do
    OpenIDConnect.Fixtures.send_response(conn, status, body, headers)
  end

  defp handle_rotating_request(
         %{request_path: "/.well-known/jwks.json"} = conn,
         _discovery,
         {status, headers},
         first,
         subsequent,
         calls
       ) do
    :counters.add(calls, 1, 1)
    pubkey = if :counters.get(calls, 1) == 1, do: first, else: subsequent
    # Wrap in `keys` so JOSE.JWK.from/1 produces a jwk_set, matching real JWKS endpoints.
    OpenIDConnect.Fixtures.send_response(conn, status, %{"keys" => [pubkey]}, headers)
  end
end
