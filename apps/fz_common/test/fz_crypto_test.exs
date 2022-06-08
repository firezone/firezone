defmodule FzCommon.FzCryptoTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzCrypto

  describe "psk/0" do
    test "it returns a string of proper length" do
      assert 44 == String.length(FzCrypto.psk())
    end
  end

  describe "rand_string/1" do
    test "it returns a string of default length" do
      assert 16 == String.length(FzCrypto.rand_string())
    end

    test "it returns a string of proper length" do
      for length <- [1, 32, 32_768] do
        assert length == String.length(FzCrypto.rand_string(length))
      end
    end
  end

  describe "rand_token/1" do
    test "returns a token of default length" do
      # 8 bytes is 12 chars in Base64
      assert 12 == String.length(FzCrypto.rand_token())
    end

    test "returns a token of length 4 when bytes is 1" do
      assert 4 == String.length(FzCrypto.rand_token(1))
    end

    test "returns a token of length 4 when bytes is 3" do
      assert 4 == String.length(FzCrypto.rand_token(3))
    end

    test "returns a token of length 40_000 when bytes is 32_768" do
      assert 44 == String.length(FzCrypto.rand_token(32))
    end

    test "returns a token of length 44 when bytes is 32" do
      assert 43_692 == String.length(FzCrypto.rand_token(32_768))
    end
  end
end
