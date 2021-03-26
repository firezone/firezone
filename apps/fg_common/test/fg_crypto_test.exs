defmodule FgCommon.FgCryptoTest do
  use ExUnit.Case, async: true

  alias FgCommon.FgCrypto

  describe "rand_string" do
    test "it returns a string of default length" do
      assert 16 == String.length(FgCrypto.rand_string())
    end

    test "it returns a string of proper length" do
      for length <- [1, 32, 32_768] do
        assert length == String.length(FgCrypto.rand_string(length))
      end
    end
  end
end
