defmodule FzHttp.QueriesTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Queries.INET

  describe "next_available/1 when none available" do
    @expected_ipv4 %Postgrex.INET{address: {10, 3, 2, 2}, netmask: nil}
    @expected_ipv6 %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: nil}

    test "when ipv4 network is /32 returns null" do
      stub_app_env(:wireguard_ipv4_network, "10.3.2.2/32")

      assert is_nil(INET.next_available(:ipv4))
    end

    test "when ipv6 network is /128 returns null" do
      stub_app_env(:wireguard_ipv6_network, "fd00::3:2:2/128")

      assert is_nil(INET.next_available(:ipv6))
    end
  end

  describe "next_available/1 when edge case" do
    setup :create_device

    @expected_ipv4 %Postgrex.INET{address: {10, 3, 2, 2}, netmask: 32}
    @expected_ipv6 %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: 128}

    test "when ipv4 network is /30 returns null", %{device: device} do
      stub_app_env(:wireguard_ipv4_network, "10.3.2.0/30")

      assert device.ipv4 == @expected_ipv4
      assert is_nil(INET.next_available(:ipv4))
    end

    test "when ipv6 network is /126 returns null", %{device: device} do
      stub_app_env(:wireguard_ipv6_network, "fd00::3:2:0/126")

      assert device.ipv6 == @expected_ipv6
      assert is_nil(INET.next_available(:ipv6))
    end
  end

  describe "next_available/1 when available" do
    @expected_ipv4 %Postgrex.INET{address: {10, 3, 2, 2}, netmask: nil}
    @expected_ipv6 %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: nil}

    setup do
      stub_app_env(:wireguard_ipv4_network, "10.3.2.0/24")
      stub_app_env(:wireguard_ipv6_network, "fd00::3:2:0/120")

      :ok
    end

    test "when ipv4 network is /24 returns 10.3.2.2" do
      assert INET.next_available(:ipv4) == @expected_ipv4
    end

    test "when ipv6 network is /120 returns fd00::3:2:2" do
      assert INET.next_available(:ipv6) == @expected_ipv6
    end
  end
end
