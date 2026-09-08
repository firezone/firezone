defmodule Portal.Types.IPTest do
  use ExUnit.Case, async: true

  alias Portal.Types.IP

  @mapped {0, 0, 0, 0, 0, 0xFFFF, 0x6BC5, 0x6844}
  @ipv4 {107, 197, 104, 68}

  describe "unmap/1" do
    test "converts an IPv4-mapped IPv6 address to IPv4" do
      assert IP.unmap(@mapped) == @ipv4
    end

    test "leaves other addresses unchanged" do
      assert IP.unmap(@ipv4) == @ipv4
      assert IP.unmap({0x2601, 0, 0, 0, 0, 0, 0, 1}) == {0x2601, 0, 0, 0, 0, 0, 0, 1}
      assert IP.unmap(nil) == nil
    end
  end

  describe "cast/1" do
    test "normalizes an IPv4-mapped IPv6 address to IPv4" do
      assert IP.cast(@mapped) == {:ok, %Postgrex.INET{address: @ipv4}}
      assert IP.cast("::ffff:107.197.104.68") == {:ok, %Postgrex.INET{address: @ipv4}}
      assert IP.cast(%Postgrex.INET{address: @mapped}) == {:ok, %Postgrex.INET{address: @ipv4}}

      assert IP.cast(%Postgrex.INET{address: @mapped, netmask: 128}) ==
               {:ok, %Postgrex.INET{address: @ipv4}}
    end

    test "keeps an IPv4-mapped block that is not a single host" do
      block = %Postgrex.INET{address: {0, 0, 0, 0, 0, 0xFFFF, 0, 0}, netmask: 96}
      assert IP.cast(block) == {:ok, block}
    end

    test "leaves other addresses unchanged" do
      assert IP.cast(@ipv4) == {:ok, %Postgrex.INET{address: @ipv4}}

      assert IP.cast({0x2601, 0, 0, 0, 0, 0, 0, 1}) ==
               {:ok, %Postgrex.INET{address: {0x2601, 0, 0, 0, 0, 0, 0, 1}}}
    end
  end

  describe "dump/1" do
    test "normalizes an IPv4-mapped IPv6 address to IPv4" do
      assert IP.dump(@mapped) == {:ok, %Postgrex.INET{address: @ipv4}}
      assert IP.dump(%Postgrex.INET{address: @mapped}) == {:ok, %Postgrex.INET{address: @ipv4}}
    end
  end

  describe "load/1" do
    test "normalizes an IPv4-mapped IPv6 address stored before normalization" do
      assert IP.load(%Postgrex.INET{address: @mapped}) == {:ok, %Postgrex.INET{address: @ipv4}}

      assert IP.load(%Postgrex.INET{address: @mapped, netmask: 128}) ==
               {:ok, %Postgrex.INET{address: @ipv4}}
    end

    test "leaves other addresses unchanged" do
      assert IP.load(%Postgrex.INET{address: @ipv4}) == {:ok, %Postgrex.INET{address: @ipv4}}
    end
  end
end
