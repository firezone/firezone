defmodule FzCommon.FzNetTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzNet

  describe "standardized_inet/1" do
    test "sanitizes CIDRs with invalid start" do
      assert "10.0.0.0/24" == FzNet.standardized_inet("10.0.0.5/24")
    end

    test "formats CIDRs" do
      assert "::/0" == FzNet.standardized_inet("::0/0")
    end

    test "formats IP address" do
      assert "fd00:3::1" == FzNet.standardized_inet("fd00:3:0000::1")
    end
  end

  describe "endpoint_to_ip/1" do
    test "IPv4" do
      assert "192.168.1.1" == FzNet.endpoint_to_ip("192.168.1.1:4562")
    end

    test "short IPv6s" do
      assert "2600::1" == FzNet.endpoint_to_ip("[2600::1]:4562")
    end

    test "expanded IPv6s" do
      assert "2600:1:1:1:1:1:1:1" == FzNet.endpoint_to_ip("[2600:1:1:1:1:1:1:1]:4562")
    end
  end
end
