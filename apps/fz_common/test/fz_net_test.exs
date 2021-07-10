defmodule FzCommon.FzNetTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzNet

  describe "ip_type" do
    test "it detects IPv4 addresses" do
      assert FzNet.ip_type("127.0.0.1") == "IPv4"
    end

    test "it detects IPv6 addresses" do
      assert FzNet.ip_type("::1") == "IPv6"
    end

    test "it reports \"unknown\" for unknown type" do
      assert FzNet.ip_type("invalid") == "unknown"
    end
  end
end
