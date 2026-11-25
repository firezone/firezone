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

  describe "rate_limit_key/1" do
    test "keeps IPv4 addresses whole" do
      assert IP.rate_limit_key({192, 0, 2, 1}) == "192.0.2.1"
    end

    test "groups IPv4-mapped IPv6 addresses with their IPv4 form" do
      assert IP.rate_limit_key({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}) == "192.0.2.1"
    end

    test "groups IPv6 addresses by /64" do
      assert IP.rate_limit_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) == "2001:db8:1:2::/64"
      assert IP.rate_limit_key({0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}) == "2001:db8:1:2::/64"
      assert IP.rate_limit_key({0x2001, 0xDB8, 1, 3, 3, 4, 5, 6}) == "2001:db8:1:3::/64"
    end
  end
end
