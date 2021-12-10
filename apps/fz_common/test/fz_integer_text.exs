defmodule FzCommon.FzIntegerTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzInteger

  describe "clamp/3" do
    test "clamps to min" do
      min = 1
      max = 5
      num = 0

      assert 1 == FzInteger.clamp(num, min, max)
    end

    test "clamps to max" do
      min = 1
      max = 5
      num = 7

      assert 5 == FzInteger.clamp(num, min, max)
    end

    test "returns num if in range" do
      min = 1
      max = 5
      num = 3

      assert 3 == FzInteger.clamp(num, min, max)
    end
  end
end
