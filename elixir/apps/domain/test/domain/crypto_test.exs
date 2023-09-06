defmodule Domain.CryptoTest do
  use ExUnit.Case, async: true
  import Domain.Crypto

  describe "psk/0" do
    test "it returns a string of proper length" do
      assert 44 == String.length(psk())
    end
  end

  describe "rand_number/1" do
    test "generates random number" do
      assert rand_number() != rand_number()
    end

    test "it returns a string of default length" do
      assert String.length(rand_number()) == 8
    end

    test "it returns a string of proper length" do
      for length <- [1, 2, 4, 16, 32], _i <- 0..100 do
        assert length == String.length(rand_number(length))
      end
    end
  end

  describe "rand_string/1" do
    test "generates random string" do
      assert rand_string() != rand_string()
    end

    test "it returns a string of default length" do
      assert 16 == String.length(rand_string())
    end

    test "it returns a string of proper length" do
      for length <- [1, 32, 32_768] do
        assert length == String.length(rand_string(length))
      end
    end
  end

  describe "rand_token/1" do
    test "generates random string" do
      assert rand_token() != rand_token()
    end

    test "returns a token of default length" do
      # 8 bytes is 12 chars in Base64 minus 1 char for the padding
      assert 11 == String.length(rand_token())
    end

    test "returns a token of length 4 when bytes is 1" do
      # 2 padding bytes are stripped
      assert 2 == String.length(rand_token(1))
    end

    test "returns a token of length 4 when bytes is 3" do
      assert 4 == String.length(rand_token(3))
    end

    test "returns a token of length 40_000 when bytes is 32_768" do
      assert 43 == String.length(rand_token(32))
    end

    test "returns a token of length 44 when bytes is 32" do
      assert 43_691 == String.length(rand_token(32_768))
    end
  end
end
