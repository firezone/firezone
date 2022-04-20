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

  describe "to_human_bytes/1" do
    @expected [
      {1_023, "1023 B"},
      {1_023_999, "1024 KiB"},
      {1_023_999_999, "1024 MiB"},
      {1_023_999_999_999, "1024 GiB"},
      {1_023_999_999_999_999, "1024 TiB"},
      {1_023_999_999_999_999_999, "1024 PiB"},
      {1_023_999_999_999_999_999_999, "1024 EiB"},
      {1_000, "1000 B"},
      {1_115, "1.09 KiB"},
      {1_000_115, "1.09 MiB"},
      {1_123_456_789, "1.05 GiB"},
      {1_123_456_789_123, "1.02 TiB"},
      {9_123_456_789_123_456, "8.1 PiB"},
      {987_654_321_123_456_789_987, "856.65 EiB"}
    ]

    test "handles expected cases" do
      for {bytes, str} <- @expected do
        assert FzInteger.to_human_bytes(bytes) == str
      end
    end
  end
end
