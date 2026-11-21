defmodule Portal.Relay.CandidateIPsTest do
  use ExUnit.Case, async: true

  alias Portal.Relay.CandidateIPs

  describe "extract/1" do
    test "takes the connection address of every candidate type" do
      candidates = [
        "candidate:1 1 udp 2130706431 192.168.1.10 51000 typ host",
        "candidate:2 1 udp 1694498815 203.0.113.5 51000 typ srflx raddr 192.168.1.10 rport 51000",
        "candidate:3 1 udp 16777215 198.51.100.7 3478 typ relay raddr 203.0.113.5 rport 51000",
        "candidate:4 1 udp 1845501695 2001:db8::1 51000 typ prflx"
      ]

      assert CandidateIPs.extract(candidates) == [
               "192.168.1.10",
               "203.0.113.5",
               "198.51.100.7",
               "2001:db8::1"
             ]
    end

    test "skips candidates whose address is not an IP" do
      candidates = [
        "candidate:1 1 udp 2130706431 4c6f1a2b-3d4e.local 51000 typ host",
        "foo",
        ""
      ]

      assert CandidateIPs.extract(candidates) == []
    end

    test "collapses duplicate IPs" do
      candidates = [
        "candidate:1 1 udp 2130706431 192.168.1.10 51000 typ host",
        "candidate:2 1 udp 2130706431 192.168.1.10 51001 typ host"
      ]

      assert CandidateIPs.extract(candidates) == ["192.168.1.10"]
    end

    test "normalises IPv6 spelling" do
      candidates = [
        "candidate:1 1 udp 2130706431 2001:0DB8:0000:0000:0000:0000:0000:0001 51000 typ host",
        "candidate:2 1 udp 2130706431 2001:db8::1 51000 typ host"
      ]

      assert CandidateIPs.extract(candidates) == ["2001:db8::1"]
    end
  end
end
