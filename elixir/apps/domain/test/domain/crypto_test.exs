defmodule Domain.CryptoTest do
  use ExUnit.Case, async: true
  import Domain.Crypto

  describe "psk/0" do
    test "it returns a string of proper length" do
      assert 44 == String.length(psk())
    end
  end

  describe "random_token/2" do
    test "generates random number" do
      assert random_token(16, generator: :numeric) != random_token(16, generator: :numeric)
    end

    test "generates random string" do
      assert random_token(16, generator: :binary) != random_token(16, generator: :binary)
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
      # 2 padding bytes are stripped
      assert String.length(random_token(1)) == 2
      assert String.length(random_token(3)) == 4
    end

    test "returns base64  encoded token doesn't remove padding" do
      assert String.length(random_token(1, encoder: :base64)) == 4
    end

    test "user friendly encoder does not print ambiguous or upcased characters" do
      for _ <- 1..100 do
        token = random_token(16, encoder: :user_friendly)
        assert String.downcase(token) == token
        assert String.printable?(token)
        refute String.contains?(token, ["-", "+", "/", "l", "I", "O", "0"])
      end
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
  end

  describe "equal?/3" do
    test "returns false for empty strings" do
      refute equal?(:argon2, "a", "")
      refute equal?(:argon2, "", "a")
      refute equal?(:sha, "a", "")
      refute equal?(:sha, "", "a")
      refute equal?(:sha3_256, "a", "")
      refute equal?(:sha3_256, "", "a")
    end

    test "returns false for nils" do
      refute equal?(:argon2, nil, "")
      refute equal?(:argon2, "", nil)
      refute equal?(:sha, nil, "")
      refute equal?(:sha, "", nil)
      refute equal?(:sha3_256, nil, "")
      refute equal?(:sha3_256, "", nil)
    end
  end

  describe "hash/2 and equal?/3" do
    test "generates a valid hash of a given value" do
      for algo <- [:sha, :sha3_256, :argon2, :blake2b], value <- ["foo", random_token()] do
        hash = hash(algo, value)

        assert is_binary(hash)
        assert hash != value

        assert equal?(algo, value, hash)
        refute equal?(algo, random_token(), hash)
        refute equal?(algo, "", hash)
        refute equal?(algo, nil, hash)
      end
    end
  end
end
