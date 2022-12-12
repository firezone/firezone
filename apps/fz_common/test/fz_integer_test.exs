defmodule FzCommon.FzIntegerTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzInteger

  describe "max_pg_integer/0" do
    test "returns max integer for postgres" do
      assert 2_147_483_647 == FzInteger.max_pg_integer()
    end
  end

  describe "from_inet4/1" do
    test "converts {255, 255, 255, 255} to 4,294,967,296" do
      assert FzInteger.from_inet({255, 255, 255, 255}) == 2 ** 32 - 1
    end

    test "converts {0, 0, 0, 0} to 0" do
      assert FzInteger.from_inet({0, 0, 0, 0}) == 0
    end

    test "converts {1, 1, 1, 1} to 16_843_009" do
      assert FzInteger.from_inet({1, 1, 1, 1}) == 16_843_009
    end
  end

  describe "from_inet6/1" do
    test "converts {65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535} to integer" do
      assert FzInteger.from_inet({65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535}) ==
               2 ** 128 - 1
    end

    test "converts {0, 0, 0, 0, 0, 0, 0, 0} to 0" do
      assert FzInteger.from_inet({0, 0, 0, 0, 0, 0, 0, 0}) == 0
    end

    test "converts {1, 1, 1, 1, 1, 1, 1, 1} to " do
      assert FzInteger.from_inet({1, 1, 1, 1, 1, 1, 1, 1}) ==
               5_192_376_087_906_286_159_508_272_029_171_713
    end
  end

  describe "to_inet4/1" do
    test "converts 2**32 - 1 to {255,255,255,255}" do
      assert FzInteger.to_inet4(2 ** 32 - 1) == {255, 255, 255, 255}
    end

    test "converts 0 to {0,0,0,0}" do
      assert FzInteger.to_inet4(0) == {0, 0, 0, 0}
    end

    test "converts 16_843_009 to {1,1,1,1}" do
      assert FzInteger.to_inet4(16_843_009) == {1, 1, 1, 1}
    end
  end

  describe "to_inet6/1" do
    test "converts 2**128 - 1 to {65_535,65_535,65_535,65_535,65_535,65_535,65_535,65_535}" do
      assert FzInteger.to_inet6(2 ** 128 - 1) ==
               {65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535}
    end

    test "converts 0 to {0,0,0,0,0,0,0,0,0}" do
      assert FzInteger.to_inet6(0) == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "converts 1_334_440_654_591_915_542_993_625_911_497_130_241 to {1, 1, 1, 1, 1, 1, 1, 1}" do
      assert FzInteger.to_inet6(5_192_376_087_906_286_159_508_272_029_171_713) ==
               {1, 1, 1, 1, 1, 1, 1, 1}
    end
  end

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

  describe "to_human_bytes/1" do
    @expected [
      {nil, "0.00 B"},
      {1_023, "1023.00 B"},
      {1_023_999_999_999_999_999_999, "888.18 EiB"},
      {1_000, "1000.00 B"},
      {1_115, "1.09 KiB"},
      {987_654_321_123_456_789_987, "856.65 EiB"}
    ]

    test "handles expected cases" do
      for {bytes, str} <- @expected do
        assert FzInteger.to_human_bytes(bytes) == str
      end
    end
  end
end
