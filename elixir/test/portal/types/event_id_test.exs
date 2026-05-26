defmodule Portal.Types.EventIdTest do
  use ExUnit.Case, async: true

  alias Portal.Types.EventId

  describe "build_change_log/2" do
    test "produces a 24-character lowercase hex string" do
      hex = EventId.build_change_log(1_700_000_000_000_000, 0)
      assert byte_size(hex) == 24
      assert hex == String.downcase(hex)
      assert hex =~ ~r/^[0-9a-f]{24}$/
    end

    test "encodes layout as [4 bits 0xC][52 bits seq_start][40 bits tenant_offset]" do
      seq_start = 1_700_000_000_000_000
      offset = 42
      hex = EventId.build_change_log(seq_start, offset)
      bin = Base.decode16!(hex, case: :mixed)
      assert <<0xC::4, ^seq_start::52, ^offset::40>> = bin
    end

    test "lex order matches integer order of (log_type, seq_start, offset)" do
      a = EventId.build_change_log(1_000, 0)
      b = EventId.build_change_log(1_000, 1)
      c = EventId.build_change_log(1_001, 0)
      d = EventId.build_change_log(2_000, 0)

      assert a < b
      assert b < c
      assert c < d
    end

    test "accepts the 52-bit max seq_start and 40-bit max tenant_offset" do
      max_seq = 2 ** 52 - 1
      max_off = 2 ** 40 - 1
      hex = EventId.build_change_log(max_seq, max_off)
      bin = Base.decode16!(hex, case: :mixed)
      assert <<0xC::4, ^max_seq::52, ^max_off::40>> = bin
    end

    test "raises FunctionClauseError when tenant_offset is 2^40" do
      assert_raise FunctionClauseError, fn ->
        EventId.build_change_log(0, 2 ** 40)
      end
    end

    test "raises FunctionClauseError when seq_start is 2^52" do
      assert_raise FunctionClauseError, fn ->
        EventId.build_change_log(2 ** 52, 0)
      end
    end

    test "raises FunctionClauseError on negative seq_start" do
      assert_raise FunctionClauseError, fn ->
        EventId.build_change_log(-1, 0)
      end
    end

    test "raises FunctionClauseError on negative tenant_offset" do
      assert_raise FunctionClauseError, fn ->
        EventId.build_change_log(0, -1)
      end
    end

    test "raises FunctionClauseError on non-integer inputs" do
      assert_raise FunctionClauseError, fn ->
        EventId.build_change_log("not an integer", 0)
      end

      assert_raise FunctionClauseError, fn ->
        EventId.build_change_log(0, nil)
      end
    end
  end

  describe "cast/1" do
    test "normalizes 24-char hex to lowercase" do
      assert {:ok, "abc" <> _} = EventId.cast("ABC" <> String.duplicate("0", 21))
    end

    test "accepts a 12-byte binary and encodes as lowercase hex" do
      bin = <<0xC0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
      assert {:ok, "c00000000000000000000000"} = EventId.cast(bin)
    end

    test "rejects integers" do
      assert :error = EventId.cast(123)
    end

    test "rejects nil" do
      assert :error = EventId.cast(nil)
    end

    test "rejects binaries of any other length" do
      assert :error = EventId.cast("")
      assert :error = EventId.cast("short")
      assert :error = EventId.cast(String.duplicate("a", 23))
      assert :error = EventId.cast(String.duplicate("a", 25))
    end

    test "rejects atoms and maps" do
      assert :error = EventId.cast(:foo)
      assert :error = EventId.cast(%{})
    end
  end

  describe "dump/1" do
    test "converts 24-char hex to a 12-byte binary" do
      hex = EventId.build_change_log(1_234, 5)
      assert {:ok, bin} = EventId.dump(hex)
      assert byte_size(bin) == 12
    end

    test "rejects binaries that are not 24 chars" do
      assert :error = EventId.dump("short")
      assert :error = EventId.dump(String.duplicate("a", 23))
      assert :error = EventId.dump(String.duplicate("a", 25))
    end

    test "rejects 24-char binaries that are not valid hex" do
      assert :error = EventId.dump(String.duplicate("z", 24))
    end

    test "rejects nil and non-binary inputs" do
      assert :error = EventId.dump(nil)
      assert :error = EventId.dump(123)
      assert :error = EventId.dump(%{})
    end
  end

  describe "load/1" do
    test "converts 12-byte binary to 24-char lowercase hex" do
      bin = <<0xC0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7>>
      assert {:ok, "c00000000000000000000007"} = EventId.load(bin)
    end

    test "rejects binaries that are not 12 bytes" do
      assert :error = EventId.load(<<>>)
      assert :error = EventId.load(<<0>>)
      assert :error = EventId.load(:binary.copy(<<0>>, 11))
      assert :error = EventId.load(:binary.copy(<<0>>, 13))
    end

    test "rejects nil and non-binary inputs" do
      assert :error = EventId.load(nil)
      assert :error = EventId.load(123)
      assert :error = EventId.load(%{})
    end
  end

  describe "round-trip" do
    test "cast → dump → load is lossless" do
      original = EventId.build_change_log(987_654_321, 17)
      {:ok, cast} = EventId.cast(original)
      {:ok, dumped} = EventId.dump(cast)
      {:ok, loaded} = EventId.load(dumped)
      assert loaded == original
    end
  end
end
