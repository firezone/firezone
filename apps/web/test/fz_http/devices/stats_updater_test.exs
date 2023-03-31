defmodule FzHttp.Devices.StatsUpdaterTest do
  use FzHttp.DataCase, async: true
  import FzHttp.Devices.StatsUpdater

  describe "endpoint_to_ip/1" do
    test "IPv4" do
      assert "192.168.1.1" == endpoint_to_ip("192.168.1.1:4562")
    end

    test "short IPv6s" do
      assert "2600::1" == endpoint_to_ip("[2600::1]:4562")
    end

    test "expanded IPv6s" do
      assert "2600:1:1:1:1:1:1:1" == endpoint_to_ip("[2600:1:1:1:1:1:1:1]:4562")
    end
  end
end
