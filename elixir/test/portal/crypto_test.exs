defmodule Portal.CryptoTest do
  use Portal.DataCase, async: true
  import Portal.Crypto
  import Portal.AccountFixtures
  import Portal.ClientFixtures
  import Portal.GatewayFixtures

  describe "psk/4" do
    setup do
      account = account_fixture()
      client = client_fixture(account: account)
      client_public_key = Portal.ClientFixtures.generate_public_key()
      gateway = gateway_fixture(account: account)
      gateway_public_key = gateway.latest_session.public_key

      %{
        account: account,
        client: client,
        client_public_key: client_public_key,
        gateway: gateway,
        gateway_public_key: gateway_public_key
      }
    end

    test "returns a base64 encoded string of proper length", %{
      client: client,
      client_public_key: client_public_key,
      gateway: gateway,
      gateway_public_key: gateway_public_key
    } do
      psk = psk(client, client_public_key, gateway, gateway_public_key)
      assert is_binary(psk)
      # 32 bytes base64 encoded = 44 characters
      assert 44 == String.length(psk)
    end

    test "returned value is valid base64", %{
      client: client,
      client_public_key: client_public_key,
      gateway: gateway,
      gateway_public_key: gateway_public_key
    } do
      psk = psk(client, client_public_key, gateway, gateway_public_key)
      assert {:ok, decoded} = Base.decode64(psk)
      assert byte_size(decoded) == 32
    end

    test "changes when client or gateway inputs change", %{
      account: account,
      client: client,
      client_public_key: client_public_key,
      gateway: gateway,
      gateway_public_key: gateway_public_key
    } do
      psk1 = psk(client, client_public_key, gateway, gateway_public_key)

      other_client = client_fixture(account: account)
      other_public_key = Portal.ClientFixtures.generate_public_key()
      other_psk = psk(other_client, other_public_key, gateway, gateway_public_key)

      assert other_psk != psk1

      other_gateway = gateway_fixture(account: account)
      other_gateway_public_key = other_gateway.latest_session.public_key
      other_psk = psk(client, client_public_key, other_gateway, other_gateway_public_key)

      assert other_psk != psk1
    end

    test "remains consistent across calls", %{
      client: client,
      client_public_key: client_public_key,
      gateway: gateway,
      gateway_public_key: gateway_public_key
    } do
      psk1 = psk(client, client_public_key, gateway, gateway_public_key)
      psk2 = psk(client, client_public_key, gateway, gateway_public_key)
      assert psk1 == psk2
    end

    test "uses PBKDF2-HMAC-SHA256 with proper salt structure", %{
      client: client,
      client_public_key: client_public_key,
      gateway: gateway,
      gateway_public_key: gateway_public_key
    } do
      # Generate PSK
      result = psk(client, client_public_key, gateway, gateway_public_key)

      # Manually compute expected result to verify algorithm
      secret_bytes = client.psk_base <> gateway.psk_base

      salt =
        "WG_PSK|C_ID:#{client.id}|G_ID:#{gateway.id}|C_PK:#{client_public_key}|G_PK:#{gateway_public_key}"

      expected_psk_bytes = :crypto.pbkdf2_hmac(:sha256, secret_bytes, salt, 1, 32)
      expected = Base.encode64(expected_psk_bytes)

      assert result == expected
    end

    test "different client IDs produce different PSKs even with same keys", %{
      account: account,
      gateway: gateway,
      gateway_public_key: gateway_public_key
    } do
      # Create two clients with potentially similar data
      client1 = client_fixture(account: account)
      client2 = client_fixture(account: account)
      public_key = Portal.ClientFixtures.generate_public_key()

      psk1 = psk(client1, public_key, gateway, gateway_public_key)
      psk2 = psk(client2, public_key, gateway, gateway_public_key)

      # Different client IDs should produce different PSKs
      refute psk1 == psk2
    end

    test "different gateway IDs produce different PSKs", %{
      account: account,
      client: client
    } do
      client_public_key = Portal.ClientFixtures.generate_public_key()
      gateway1 = gateway_fixture(account: account)
      gateway2 = gateway_fixture(account: account)

      psk1 = psk(client, client_public_key, gateway1, gateway1.latest_session.public_key)
      psk2 = psk(client, client_public_key, gateway2, gateway2.latest_session.public_key)

      refute psk1 == psk2
    end
  end

  describe "random_token/2" do
    test "numeric tokens only contain digits" do
      for length <- [1, 4, 16, 32], _i <- 0..10 do
        token = random_token(length, generator: :numeric)
        assert String.match?(token, ~r/^\d+$/)
      end
    end

    test "generates a random number of given length" do
      for length <- [1, 2, 4, 16, 32], _i <- 0..100 do
        assert length == String.length(random_token(length, generator: :numeric))
      end
    end

    test "generates a random binary of given byte size" do
      for length <- [1, 2, 4, 16, 32], _i <- 0..100 do
        assert length == byte_size(random_token(length, encoder: :raw))
      end
    end

    test "returns base64 url encoded token by default" do
      one_byte_token = random_token(1)
      three_byte_token = random_token(3)

      # 2 padding characters are stripped
      assert String.length(one_byte_token) == 2
      assert String.length(three_byte_token) == 4

      refute String.ends_with?(one_byte_token, "=")
      refute String.ends_with?(three_byte_token, "=")
    end

    test "returns base64 encoded token with padding characters" do
      token = random_token(1, encoder: :base64)

      assert String.length(token) == 4
      assert String.ends_with?(token, "==")
    end

    test "hex32 encoder produces valid base32 hex" do
      token = random_token(16, encoder: :hex32)
      # Base32 hex uses 0-9 and A-V, and may include padding =
      assert String.match?(token, ~r/^[0-9A-V=]+$/)
    end

    test "user friendly encoder produces safe, unambiguous tokens" do
      for length <- [8, 16, 32, 64] do
        token = random_token(length, encoder: :user_friendly)

        # Respects length parameter
        assert String.length(token) == length

        # Only lowercase characters
        assert String.downcase(token) == token
        assert String.printable?(token)

        # Never contains ambiguous characters:
        refute String.contains?(token, "-")
        refute String.contains?(token, "+")
        refute String.contains?(token, "/")
        refute String.contains?(token, "l")
        refute String.contains?(token, "I")
        refute String.contains?(token, "O")
        refute String.contains?(token, "0")
        refute String.contains?(token, "=")
        refute String.contains?(token, "_")
      end
    end

    test "default generator is binary" do
      token1 = random_token(16)
      token2 = random_token(16, generator: :binary)

      # Both should be url_encode64 by default
      assert String.match?(token1, ~r/^[A-Za-z0-9_-]+$/)
      assert String.match?(token2, ~r/^[A-Za-z0-9_-]+$/)
    end
  end

  describe "hash/2" do
    test "raises an error when secret is an empty string" do
      assert_raise FunctionClauseError, fn ->
        hash(:argon2, "")
      end

      assert_raise FunctionClauseError, fn ->
        hash(:sha256, "")
      end
    end

    test "raises an error when secret is not a binary" do
      assert_raise FunctionClauseError, fn ->
        hash(:argon2, 1)
      end

      assert_raise FunctionClauseError, fn ->
        hash(:sha256, 1)
      end
    end

    test "argon2 hash returns valid argon2 hash string" do
      hash = hash(:argon2, "password123")
      assert String.starts_with?(hash, "$argon2")
      assert is_binary(hash)
    end

    test "argon2 hash produces different results each time (due to salt)" do
      hash1 = hash(:argon2, "password123")
      hash2 = hash(:argon2, "password123")

      refute hash1 == hash2
    end

    test "non-argon2 algorithms return lowercase hex" do
      for algo <- [:sha, :sha256, :sha3_256, :blake2b] do
        hash = hash(algo, "test value")
        assert is_binary(hash)
        assert String.match?(hash, ~r/^[0-9a-f]+$/)
        refute String.match?(hash, ~r/[A-F]/)
      end
    end
  end

  describe "equal?/3" do
    test "returns false for nil and empty string edge cases" do
      for algo <- [:argon2, :sha, :sha256, :sha3_256] do
        # Empty strings
        refute equal?(algo, "a", "")
        refute equal?(algo, "", "a")
        refute equal?(algo, "", "")

        # Nils
        refute equal?(algo, nil, "a")
        refute equal?(algo, nil, "")
        refute equal?(algo, "a", nil)
        refute equal?(algo, "", nil)
        refute equal?(algo, nil, nil)
      end
    end
  end

  describe "hash/2 and equal?/3 integration" do
    test "hash and equal? work correctly together for all algorithms" do
      for algo <- [:sha, :sha256, :sha3_256, :argon2, :blake2b],
          value <- ["foo", random_token()] do
        hash = hash(algo, value)

        assert is_binary(hash)
        assert hash != value

        assert equal?(algo, value, hash)
        refute equal?(algo, random_token(), hash)
        refute equal?(algo, "", hash)
        refute equal?(algo, nil, hash)
      end
    end

    test "different hash algorithms produce different hashes for same input" do
      value = "same input"

      sha_hash = hash(:sha, value)
      sha256_hash = hash(:sha256, value)
      sha3_hash = hash(:sha3_256, value)
      blake2b_hash = hash(:blake2b, value)

      # All should be different
      assert sha_hash != sha256_hash
      assert sha_hash != sha3_hash
      assert sha_hash != blake2b_hash
      assert sha256_hash != sha3_hash
      assert sha256_hash != blake2b_hash
      assert sha3_hash != blake2b_hash
    end

    test "equal? fails when using wrong algorithm" do
      value = "test"
      sha256_hash = hash(:sha256, value)
      sha_hash = hash(:sha, value)

      # Using the correct algorithm should work
      assert equal?(:sha256, value, sha256_hash)
      assert equal?(:sha, value, sha_hash)

      # Using the wrong algorithm should fail
      refute equal?(:sha, value, sha256_hash)
      refute equal?(:sha256, value, sha_hash)
    end
  end
end
