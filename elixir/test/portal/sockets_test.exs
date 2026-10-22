defmodule Portal.SocketsTest do
  use ExUnit.Case, async: true

  alias Portal.Sockets

  @mapped {0, 0, 0, 0, 0, 0xFFFF, 0x6BC5, 0x6844}
  @ipv4 {107, 197, 104, 68}

  describe "remote_ip/1" do
    test "uses the peer address when there are no forwarding headers" do
      assert Sockets.remote_ip(%{peer_data: %{address: @ipv4}, x_headers: []}) == @ipv4
      assert Sockets.remote_ip(%{peer_data: %{address: @ipv4}}) == @ipv4
    end

    test "normalizes an IPv4-mapped IPv6 peer address to IPv4" do
      assert Sockets.remote_ip(%{peer_data: %{address: @mapped}, x_headers: []}) == @ipv4
    end

    test "prefers the forwarded address over the peer address" do
      connect_info = %{
        peer_data: %{address: {10, 0, 0, 1}},
        x_headers: [{"x-forwarded-for", "107.197.104.68"}]
      }

      assert Sockets.remote_ip(connect_info) == @ipv4
    end

    test "normalizes an IPv4-mapped IPv6 forwarded address to IPv4" do
      connect_info = %{
        peer_data: %{address: {10, 0, 0, 1}},
        x_headers: [{"x-forwarded-for", "::ffff:107.197.104.68:53859"}]
      }

      assert Sockets.remote_ip(connect_info) == @ipv4
    end

    test "skips IPv4-mapped private proxy hops in the forwarded chain" do
      connect_info = %{
        peer_data: %{address: {10, 0, 0, 1}},
        x_headers: [{"x-forwarded-for", "6.6.6.6, ::ffff:203.0.113.5, ::ffff:10.0.0.1"}]
      }

      assert Sockets.remote_ip(connect_info) == {203, 0, 113, 5}
    end
  end
end
