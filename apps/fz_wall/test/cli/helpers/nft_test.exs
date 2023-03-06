defmodule FzWall.CLI.Helpers.NftTest do
  use ExUnit.Case, async: true
  import FzWall.CLI.Helpers.Nft

  describe "standardized_inet/1" do
    test "sanitizes CIDRs with invalid start" do
      assert "10.0.0.0/24" == standardized_inet("10.0.0.5/24")
    end

    test "formats CIDRs" do
      assert "::/0" == standardized_inet("::0/0")
    end

    test "formats IP address" do
      assert "fd00:3::1" == standardized_inet("fd00:3:0000::1")
    end
  end
end
