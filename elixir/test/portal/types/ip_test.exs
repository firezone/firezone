defmodule Portal.Types.IPTest do
  use ExUnit.Case, async: true

  alias Portal.Types.IP

  describe "unmap/1" do
    test "converts an IPv4-mapped IPv6 address to IPv4" do
      assert IP.unmap({0, 0, 0, 0, 0, 0xFFFF, 0x6BC5, 0x6844}) == {107, 197, 104, 68}
    end

    test "leaves other addresses unchanged" do
      assert IP.unmap({107, 197, 104, 68}) == {107, 197, 104, 68}
      assert IP.unmap({0x2601, 0, 0, 0, 0, 0, 0, 1}) == {0x2601, 0, 0, 0, 0, 0, 0, 1}
      assert IP.unmap(nil) == nil
    end
  end
end
