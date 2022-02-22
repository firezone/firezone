defmodule FzHttp.QueriesTest do
  use FzHttp.DataCase, async: false

  alias FzHttp.Queries.INET

  describe "next_available/1 when none available" do
    @expected_ipv4 %Postgrex.INET{address: {10, 3, 2, 2}, netmask: nil}
    @expected_ipv6 %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: nil}

    setup context do
      if ipv4_network = context[:ipv4_network] do
        restore_env(:wireguard_ipv4_network, ipv4_network, &on_exit/1)
      else
        context
      end
    end

    setup context do
      if ipv6_network = context[:ipv6_network] do
        restore_env(:wireguard_ipv6_network, ipv6_network, &on_exit/1)
      else
        context
      end
    end

    @tag ipv4_network: "10.3.2.2/32"
    test "when ipv4 network is /32 returns null" do
      assert is_nil(INET.next_available(:ipv4))
    end

    @tag ipv6_network: "fd00::3:2:2/128"
    test "when ipv6 network is /128 returns null" do
      assert is_nil(INET.next_available(:ipv6))
    end
  end

  describe "next_available/1 when edge case" do
    setup :create_tunnel

    @expected_ipv4 %Postgrex.INET{address: {10, 3, 2, 2}, netmask: 32}
    @expected_ipv6 %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: 128}

    setup context do
      if ipv4_network = context[:ipv4_network] do
        restore_env(:wireguard_ipv4_network, ipv4_network, &on_exit/1)
      else
        context
      end
    end

    setup context do
      if ipv6_network = context[:ipv6_network] do
        restore_env(:wireguard_ipv6_network, ipv6_network, &on_exit/1)
      else
        context
      end
    end

    @tag ipv4_network: "10.3.2.0/30"
    test "when ipv4 network is /30 returns null", %{tunnel: tunnel} do
      assert tunnel.ipv4 == @expected_ipv4
      assert is_nil(INET.next_available(:ipv4))
    end

    @tag ipv6_network: "fd00::3:2:0/126"
    test "when ipv6 network is /126 returns null", %{tunnel: tunnel} do
      assert tunnel.ipv6 == @expected_ipv6
      assert is_nil(INET.next_available(:ipv6))
    end
  end

  describe "next_available/1 when available" do
    @expected_ipv4 %Postgrex.INET{address: {10, 3, 2, 2}, netmask: nil}
    @expected_ipv6 %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: nil}

    test "when ipv4 network is /24 returns 10.3.2.2" do
      assert INET.next_available(:ipv4) == @expected_ipv4
    end

    test "when ipv6 network is /120 returns fd00::3:2:2" do
      assert INET.next_available(:ipv6) == @expected_ipv6
    end
  end
end
