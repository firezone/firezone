defmodule FzCommon.FzIntegerTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzInteger

  describe "max_pg_integer/0" do
    test "returns max integer for postgres" do
      assert 2_147_483_647 == FzInteger.max_pg_integer()
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
