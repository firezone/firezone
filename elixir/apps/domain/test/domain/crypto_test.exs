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
end
