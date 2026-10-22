defmodule Portal.OAuth.ClientAuthenticationTest do
  use Portal.DataCase, async: true

  import Portal.OAuthFixtures
  alias Portal.OAuth.ClientAuthentication
  alias Portal.OAuth.ClientMetadata

  setup_all do
    %{
      keys: Portal.Crypto.JWK.generate_jwk_and_jwks(),
      other: Portal.Crypto.JWK.generate_jwk_and_jwks()
    }
  end

  setup %{keys: keys} do
    client =
      oauth_client_fixture(
        token_endpoint_auth_method: "private_key_jwt",
        jwks_uri: "https://localhost/jwks.json"
      )

    Req.Test.stub(ClientMetadata, &Req.Test.json(&1, keys.jwks))
    %{client: client}
  end

  test "authenticates a signed assertion and rejects replay", %{client: client, keys: keys} do
    params = assertion(client, keys)
    assert :ok = ClientAuthentication.authenticate(params, client.client_id)

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(params, client.client_id)
  end

  test "only one concurrent request can consume an assertion", %{client: client, keys: keys} do
    params = assertion(client, keys)

    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> ClientAuthentication.authenticate(params, client.client_id) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, "invalid_client", _}, &1)) == 1
  end

  test "rejects conflicting client secrets", %{client: client, keys: keys} do
    params = Map.put(assertion(client, keys), "client_secret", "ignored-secret")

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(params, client.client_id)

    public = oauth_client_fixture()

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(%{"client_secret" => "secret"}, public.client_id)
  end

  test "retains replay records beyond expiry for clock differences", %{client: client, keys: keys} do
    exp = System.system_time(:second) + 60
    jti = Ecto.UUID.generate()
    params = assertion(client, keys, %{"exp" => exp, "jti" => jti})
    assert :ok = ClientAuthentication.authenticate(params, client.client_id)
    id = :crypto.hash(:sha256, :erlang.term_to_binary({client.client_id, jti}))
    import Ecto.Query

    expiry =
      Repo.one(from(a in "oauth_client_assertions", where: a.id == ^id, select: a.expires_at))

    assert DateTime.to_unix(expiry) == exp + 60
  end

  test "key fetches have request and receive deadlines and disable implicit decoding" do
    pid = self()

    adapter = fn request ->
      send(pid, {:fetch_options, request.options})
      {request, Req.Response.new(status: 200, body: %{"keys" => [%{}]})}
    end

    config = Portal.Config.fetch_env!(:portal, ClientMetadata)

    Portal.Config.put_env_override(
      :portal,
      ClientMetadata,
      Keyword.put(config, :req_opts, adapter: adapter)
    )

    assert {:ok, [_]} = ClientMetadata.fetch_jwks("https://client.example.com/keys")
    assert_receive {:fetch_options, options}
    assert options[:request_timeout] == 5000
    assert options[:receive_timeout] == 5000
    assert options[:raw] == true
    assert options[:redirect] == false
  end

  test "binds assertions to their endpoint audience", %{client: client, keys: keys} do
    revoked = assertion(client, keys, %{"aud" => PortalWeb.Endpoint.url() <> "/oauth/revoke"})

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(revoked, client.client_id)

    assert :ok = ClientAuthentication.authenticate(revoked, client.client_id, :revoke)
    token = assertion(client, keys)

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(token, client.client_id, :revoke)
  end

  test "signed clients cannot fall back to none", %{client: client} do
    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(%{}, client.client_id)
  end

  test "public clients still work but cannot submit ignored assertions", %{
    client: signed,
    keys: keys
  } do
    client = oauth_client_fixture()
    assert :ok = ClientAuthentication.authenticate(%{}, client.client_id)

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(assertion(signed, keys), client.client_id)
  end

  test "rejects mismatched signatures and unknown keys", %{
    client: client,
    keys: keys,
    other: other
  } do
    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(assertion(client, other), client.client_id)

    forged = %{other | kid: keys.kid}

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(assertion(client, forged), client.client_id)
  end

  test "rejects algorithm confusion before fetching keys", %{client: client, keys: keys} do
    params = assertion(client, keys)
    [_, payload, signature] = String.split(params["client_assertion"], ".")
    pid = self()

    Req.Test.stub(ClientMetadata, fn conn ->
      send(pid, :keys_fetched)
      Req.Test.json(conn, keys.jwks)
    end)

    for header <- [
          %{"alg" => "none", "kid" => keys.kid},
          %{"alg" => "HS256", "kid" => keys.kid},
          %{"alg" => "RS256", "kid" => keys.kid, "crit" => ["unknown"]}
        ] do
      encoded = header |> Jason.encode!() |> Base.url_encode64(padding: false)
      invalid = %{params | "client_assertion" => Enum.join([encoded, payload, signature], ".")}

      assert {:error, "invalid_client", _} =
               ClientAuthentication.authenticate(invalid, client.client_id)
    end

    refute_receive :keys_fetched
  end

  test "rejects duplicate key IDs and keys that cannot be used for verification", %{
    client: client,
    keys: keys
  } do
    [key] = keys.jwks["keys"]

    for invalid_keys <- [
          [key, key],
          [Map.put(key, "use", "enc")],
          [Map.put(key, "alg", "HS256")],
          [Map.put(key, "d", "private-material")],
          [Map.put(key, "n", "not-base64!")],
          [Map.put(key, "key_ops", ["sign"])]
        ] do
      Req.Test.stub(ClientMetadata, &Req.Test.json(&1, %{"keys" => invalid_keys}))

      assert {:error, "invalid_client", _} =
               ClientAuthentication.authenticate(assertion(client, keys), client.client_id)
    end
  end

  test "rejects invalid claims", %{client: client, keys: keys} do
    now = System.system_time(:second)

    for changes <- [
          %{"iss" => "another-client"},
          %{"sub" => "another-client"},
          %{"aud" => "https://attacker.example/token"},
          %{"aud" => [nil]},
          %{"exp" => now - 1},
          %{"exp" => now + 3600},
          %{"exp" => "tomorrow"},
          %{"iat" => now + 60},
          %{"iat" => now - 3600},
          %{"iat" => nil},
          %{"nbf" => now + 60},
          %{"nbf" => "now"},
          %{"jti" => nil},
          %{"jti" => ""}
        ] do
      assert {:error, "invalid_client", _} =
               ClientAuthentication.authenticate(
                 assertion(client, keys, changes),
                 client.client_id
               )
    end
  end

  test "rejects malformed assertions and unsupported assertion types", %{
    client: client,
    keys: keys
  } do
    params = assertion(client, keys)

    for invalid <- [
          %{},
          %{"client_assertion" => "junk"},
          %{params | "client_assertion" => "bad.jwt.value"},
          %{params | "client_assertion" => String.duplicate("x", 8193)},
          %{params | "client_assertion_type" => "unsupported"}
        ] do
      assert {:error, "invalid_client", _} =
               ClientAuthentication.authenticate(invalid, client.client_id)
    end
  end

  test "fetches current keys after rotation", %{client: client, keys: keys, other: other} do
    assert :ok = ClientAuthentication.authenticate(assertion(client, keys), client.client_id)
    Req.Test.stub(ClientMetadata, &Req.Test.json(&1, other.jwks))
    assert :ok = ClientAuthentication.authenticate(assertion(client, other), client.client_id)

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(assertion(client, keys), client.client_id)
  end

  test "fails closed on unavailable, oversized, or malformed JWKS", %{client: client, keys: keys} do
    for body <- [
          %{},
          %{"keys" => []},
          %{"keys" => [nil]},
          %{"keys" => List.duplicate(%{}, 17)},
          String.duplicate("x", 32769)
        ] do
      Req.Test.stub(ClientMetadata, &Req.Test.json(&1, body))

      assert {:error, "invalid_client", _} =
               ClientAuthentication.authenticate(assertion(client, keys), client.client_id)
    end

    Req.Test.stub(ClientMetadata, &Plug.Conn.send_resp(&1, 503, "unavailable"))

    assert {:error, "invalid_client", _} =
             ClientAuthentication.authenticate(assertion(client, keys), client.client_id)
  end

  test "rejects unsafe or malformed JWKS URLs before requesting them" do
    for uri <- [
          "http://client.example.com/keys",
          "https://user:secret@client.example.com/keys",
          "https://client.example.com/keys#fragment",
          "https://client.example.com:bad/keys",
          "https://client.example.com:65536/keys",
          "https://client.example.com:0/keys",
          "not-a-url"
        ] do
      assert {:error, :invalid_jwks} = ClientMetadata.fetch_jwks(uri)

      assert {:error, :invalid_document} =
               ClientMetadata.authentication_method(%{
                 "token_endpoint_auth_method" => "private_key_jwt",
                 "jwks_uri" => uri
               })
    end
  end

  test "JWKS requests keep mandatory SSRF protection" do
    pid = self()

    adapter = fn request ->
      send(pid, :unsafe_fetch)
      {request, Req.Response.new(status: 200, body: %{"keys" => []})}
    end

    Portal.Config.put_env_override(:portal, ClientMetadata,
      req_opts: [plugins: [], adapter: adapter]
    )

    # The public API normalizes the protected fetch failure, without invoking the adapter.
    assert {:error, :invalid_jwks} = ClientMetadata.fetch_jwks("https://127.0.0.1/keys.json")
    refute_receive :unsafe_fetch
  end

  defp assertion(client, keys, changes \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => client.client_id,
          "sub" => client.client_id,
          "aud" => PortalWeb.Endpoint.url() <> "/oauth/token",
          "iat" => now,
          "exp" => now + 60,
          "jti" => Ecto.UUID.generate()
        },
        changes
      )

    {_, token} =
      keys.jwk
      |> JOSE.JWK.from_map()
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => keys.kid}, claims)
      |> JOSE.JWS.compact()

    %{
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => token
    }
  end
end
