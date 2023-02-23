defmodule FzWall.CLI.LiveTest do
  use ExUnit.Case

  describe "proto/1" do
    import FzWall.CLI.Live, only: [proto: 1]

    test "handles ipv4 addresses" do
      assert proto("100.64.0.1") == :ip
    end

    test "handles ipv6 addresses" do
      assert proto("fd00::1") == :ip6
    end

    test "handles ipv4 cidrs" do
      assert proto("100.64.0.0/10") == :ip
    end

    test "handles ipv6 cidrs" do
      assert proto("fd00::/106") == :ip6
    end
  end
end
