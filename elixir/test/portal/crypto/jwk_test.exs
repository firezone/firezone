defmodule Portal.Crypto.JWKTest do
  use ExUnit.Case, async: true
  alias Portal.Crypto.JWK

  describe "generate_jwk_and_jwks/0" do
    test "generates JWK and JWKS with default 2048 bits" do
      result = JWK.generate_jwk_and_jwks()

      # Verify return structure
      assert is_map(result)
      assert is_map(result.jwk)
      assert is_map(result.jwks)
      assert is_binary(result.kid)

      # Verify the modulus (n) is exactly 2048 bits
      n_binary = Base.url_decode64!(result.jwk["n"], padding: false)
      n_bits = bit_size(n_binary)

      assert n_bits == 2048
    end

    test "JWK contains all required private key fields" do
      result = JWK.generate_jwk_and_jwks()
      jwk = result.jwk

      assert jwk["kty"] == "RSA"
      assert jwk["alg"] == "RS256"
      assert jwk["use"] == "sig"
      assert is_binary(jwk["kid"])
      assert is_binary(jwk["n"])
      assert is_binary(jwk["e"])
      assert is_binary(jwk["d"])
      assert is_binary(jwk["p"])
      assert is_binary(jwk["q"])
      assert is_binary(jwk["dp"])
      assert is_binary(jwk["dq"])
      assert is_binary(jwk["qi"])
    end

    test "JWK values are base64url encoded without padding" do
      result = JWK.generate_jwk_and_jwks()
      jwk = result.jwk

      for field <- ["n", "e", "d", "p", "q", "dp", "dq", "qi"] do
        value = jwk[field]
        assert is_binary(value)
        refute String.contains?(value, "=")
        assert String.match?(value, ~r/^[A-Za-z0-9_-]+$/)
      end
    end

    test "JWKS contains public keys array" do
      result = JWK.generate_jwk_and_jwks()
      jwks = result.jwks

      assert is_map(jwks)
      assert Map.has_key?(jwks, "keys")
      assert is_list(jwks["keys"])
      assert length(jwks["keys"]) == 1
    end

    test "JWKS public key contains only public fields" do
      result = JWK.generate_jwk_and_jwks()
      public_key = List.first(result.jwks["keys"])

      assert public_key["kty"] == "RSA"
      assert public_key["alg"] == "RS256"
      assert public_key["use"] == "sig"
      assert is_binary(public_key["kid"])
      assert is_binary(public_key["n"])
      assert is_binary(public_key["e"])

      # Ensure no private fields
      refute Map.has_key?(public_key, "d")
      refute Map.has_key?(public_key, "p")
      refute Map.has_key?(public_key, "q")
      refute Map.has_key?(public_key, "dp")
      refute Map.has_key?(public_key, "dq")
      refute Map.has_key?(public_key, "qi")
    end

    test "kid in JWK matches kid in JWKS" do
      result = JWK.generate_jwk_and_jwks()
      jwk_kid = result.jwk["kid"]
      jwks_kid = List.first(result.jwks["keys"])["kid"]

      assert jwk_kid == jwks_kid
      assert jwk_kid == result.kid
    end

    test "kid is RFC 7638 compliant thumbprint" do
      result = JWK.generate_jwk_and_jwks()

      # Manually calculate the thumbprint according to RFC 7638
      thumbprint_json =
        JSON.encode!(%{
          "e" => result.jwk["e"],
          "kty" => result.jwk["kty"],
          "n" => result.jwk["n"]
        })

      expected_kid = :crypto.hash(:sha256, thumbprint_json) |> Base.url_encode64(padding: false)

      assert result.kid == expected_kid
      assert result.jwk["kid"] == expected_kid
    end

    test "kid is base64url encoded SHA256 hash without padding" do
      result = JWK.generate_jwk_and_jwks()

      assert is_binary(result.kid)
      refute String.contains?(result.kid, "=")
      assert String.match?(result.kid, ~r/^[A-Za-z0-9_-]+$/)
      # SHA256 hash is 32 bytes, base64url encoded without padding should be 43 chars
      assert String.length(result.kid) == 43
    end

    test "public key n and e values match in JWK and JWKS" do
      result = JWK.generate_jwk_and_jwks()
      public_key = List.first(result.jwks["keys"])

      assert result.jwk["n"] == public_key["n"]
      assert result.jwk["e"] == public_key["e"]
    end

    test "generates unique JWKs on each invocation" do
      result1 = JWK.generate_jwk_and_jwks()
      result2 = JWK.generate_jwk_and_jwks()

      refute result1.jwk["n"] == result2.jwk["n"]
      refute result1.jwk["d"] == result2.jwk["d"]
      refute result1.kid == result2.kid
    end

    test "public exponent is 65537" do
      result = JWK.generate_jwk_and_jwks()

      # Decode the base64url encoded exponent
      e_binary = Base.url_decode64!(result.jwk["e"], padding: false)
      e_int = :binary.decode_unsigned(e_binary)

      assert e_int == 65_537
    end
  end

  describe "generate_jwk_and_jwks/1" do
    test "generates JWK with custom bit size" do
      for bits <- [1024, 2048, 4096] do
        result = JWK.generate_jwk_and_jwks(bits)

        assert is_map(result)
        assert Map.has_key?(result, :jwk)
        assert Map.has_key?(result, :jwks)
        assert is_binary(result.jwk["n"])
        assert is_binary(result.jwk["e"])
        assert is_binary(result.kid)

        # Verify the modulus (n) size is exactly the requested bit size
        n_binary = Base.url_decode64!(result.jwk["n"], padding: false)
        n_bits = bit_size(n_binary)

        assert n_bits == bits
      end
    end
  end

  describe "extract_public_key_components/1" do
    test "extracts only public key fields from private JWK" do
      result = JWK.generate_jwk_and_jwks()
      public_jwk = JWK.extract_public_key_components(result.jwk)

      assert public_jwk["kty"] == "RSA"
      assert public_jwk["alg"] == "RS256"
      assert public_jwk["use"] == "sig"
      assert public_jwk["kid"] == result.jwk["kid"]
      assert public_jwk["n"] == result.jwk["n"]
      assert public_jwk["e"] == result.jwk["e"]

      # Verify no private fields are extracted
      refute Map.has_key?(public_jwk, "d")
      refute Map.has_key?(public_jwk, "p")
      refute Map.has_key?(public_jwk, "q")
      refute Map.has_key?(public_jwk, "dp")
      refute Map.has_key?(public_jwk, "dq")
      refute Map.has_key?(public_jwk, "qi")
    end

    test "extracted public key matches JWKS public key" do
      result = JWK.generate_jwk_and_jwks()
      extracted = JWK.extract_public_key_components(result.jwk)
      jwks_public = List.first(result.jwks["keys"])

      assert extracted == jwks_public
    end

    test "preserves all public fields exactly" do
      result = JWK.generate_jwk_and_jwks()
      public_jwk = JWK.extract_public_key_components(result.jwk)

      # Verify no transformation of values
      assert public_jwk["n"] == result.jwk["n"]
      assert public_jwk["e"] == result.jwk["e"]
      assert public_jwk["kid"] == result.jwk["kid"]
      assert public_jwk["kty"] == result.jwk["kty"]
      assert public_jwk["alg"] == result.jwk["alg"]
      assert public_jwk["use"] == result.jwk["use"]
    end
  end

  describe "integration with JOSE libraries" do
    # test "generated JWK can be used to sign JWT tokens" do
    #  result = JWK.generate_jwk_and_jwks()

    #  # Sign with JOSE
    #  jwk = JOSE.JWK.from_map(result.jwk)
    #  jws = %{"alg" => "RS256"}
    #  {_jws, token} = JOSE.JWT.sign(jwk, jws, payload) |> JOSE.JWS.compact()

    #  assert is_binary(token)
    #  assert String.contains?(token, ".")
    # end

    test "generated JWKS can be used to sign and verify JWT tokens" do
      result = JWK.generate_jwk_and_jwks()
      time = System.system_time(:second)

      # Create a simple JWT payload
      payload = %{
        "sub" => "test-user",
        "iat" => time,
        "exp" => time + 3600
      }

      # Create and sign a token
      jwk = JOSE.JWK.from_map(result.jwk)
      jws = %{"alg" => "RS256"}
      {_jws, token} = JOSE.JWT.sign(jwk, jws, payload) |> JOSE.JWS.compact()

      assert is_binary(token)
      assert String.split(token, ".", parts: 3) |> length() == 3

      # Verify with public key from JWKS
      public_jwk = List.first(result.jwks["keys"])
      public_key = JOSE.JWK.from_map(public_jwk)

      {verified, decoded_payload, _jws} = JOSE.JWT.verify(public_key, token)

      assert verified
      assert decoded_payload.fields["sub"] == "test-user"
      assert decoded_payload.fields["iat"] == time
      assert decoded_payload.fields["exp"] == time + 3600
    end

    test "verification fails with wrong public key" do
      result1 = JWK.generate_jwk_and_jwks()
      result2 = JWK.generate_jwk_and_jwks()

      # Sign with result1's private key
      payload = %{"sub" => "test-user"}
      jwk1 = JOSE.JWK.from_map(result1.jwk)
      jws = %{"alg" => "RS256"}
      {_jws, token} = JOSE.JWT.sign(jwk1, jws, payload) |> JOSE.JWS.compact()

      # Try to verify with result2's public key
      public_jwk2 = List.first(result2.jwks["keys"])
      public_key2 = JOSE.JWK.from_map(public_jwk2)

      {verified, _decoded, _jws} = JOSE.JWT.verify(public_key2, token)

      refute verified
    end
  end

  describe "JWK mathematical properties" do
    test "RSA private key components satisfy mathematical relationships" do
      result = JWK.generate_jwk_and_jwks()
      jwk = result.jwk

      # Decode all components
      n = jwk["n"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      e = jwk["e"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      p = jwk["p"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      q = jwk["q"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()

      # Verify n = p * q
      assert n == p * q

      # Verify e is 65537
      assert e == 65_537
    end

    test "dp and dq are correctly computed" do
      result = JWK.generate_jwk_and_jwks()
      jwk = result.jwk

      # Decode components
      d = jwk["d"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      p = jwk["p"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      q = jwk["q"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      dp = jwk["dp"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      dq = jwk["dq"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()

      # dp should equal d mod (p-1)
      assert dp == rem(d, p - 1)

      # dq should equal d mod (q-1)
      assert dq == rem(d, q - 1)
    end

    test "qi (CRT coefficient) satisfies q * qi ≡ 1 (mod p)" do
      result = JWK.generate_jwk_and_jwks()
      jwk = result.jwk

      # Decode components
      p = jwk["p"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      q = jwk["q"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
      qi = jwk["qi"] |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()

      # Verify q * qi ≡ 1 (mod p)
      result = rem(q * qi, p)
      assert result == 1
    end
  end

  describe "base64url encoding" do
    test "all encoded values use URL-safe characters only" do
      result = JWK.generate_jwk_and_jwks()

      for field <- ["n", "e", "d", "p", "q", "dp", "dq", "qi"] do
        value = result.jwk[field]
        # Should only contain A-Z, a-z, 0-9, -, _
        assert String.match?(value, ~r/^[A-Za-z0-9_-]+$/)
        # Should not contain standard base64 characters +, /, or padding =
        refute String.contains?(value, "+")
        refute String.contains?(value, "/")
        refute String.contains?(value, "=")
      end
    end

    test "kid uses URL-safe base64 encoding" do
      result = JWK.generate_jwk_and_jwks()

      assert String.match?(result.kid, ~r/^[A-Za-z0-9_-]+$/)
      refute String.contains?(result.kid, "+")
      refute String.contains?(result.kid, "/")
      refute String.contains?(result.kid, "=")
    end

    test "encoded values can be decoded back" do
      result = JWK.generate_jwk_and_jwks()

      for field <- ["n", "e", "d", "p", "q", "dp", "dq", "qi"] do
        value = result.jwk[field]
        # Should be decodable
        assert {:ok, _decoded} = Base.url_decode64(value, padding: false)
      end
    end
  end

  describe "RFC 7638 thumbprint compliance" do
    test "thumbprint uses lexicographically sorted keys" do
      result = JWK.generate_jwk_and_jwks()

      # RFC 7638 requires keys to be in lexicographic order: e, kty, n
      thumbprint_json =
        JSON.encode!(%{
          "e" => result.jwk["e"],
          "kty" => result.jwk["kty"],
          "n" => result.jwk["n"]
        })

      # Verify the keys appear in lexicographic order in the serialized JSON
      # Find the positions of each key
      e_pos = :binary.match(thumbprint_json, ~s("e":)) |> elem(0)
      kty_pos = :binary.match(thumbprint_json, ~s("kty":)) |> elem(0)
      n_pos = :binary.match(thumbprint_json, ~s("n":)) |> elem(0)

      # Keys must appear in order: e, kty, n
      assert e_pos < kty_pos, "Key 'e' must appear before 'kty'"
      assert kty_pos < n_pos, "Key 'kty' must appear before 'n'"
    end

  end
end
