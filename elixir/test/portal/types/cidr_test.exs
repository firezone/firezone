defmodule Portal.Types.CIDRTest do
  use ExUnit.Case, async: true
  import Portal.Types.CIDR

  describe "count_hosts/2" do
    test "ipv4" do
      address = {1, 0, 0, 0}
      assert count_hosts(%Postgrex.INET{address: address, netmask: 24}) == 256
      assert count_hosts(%Postgrex.INET{address: address, netmask: 28}) == 16
      assert count_hosts(%Postgrex.INET{address: address, netmask: 31}) == 2
    end

    test "ipv6" do
      address = {8193, 0, 0, 0, 0, 0, 0, 1}

      assert count_hosts(%Postgrex.INET{address: address, netmask: 32}) ==
               79_228_162_514_264_337_593_543_950_336

      assert count_hosts(%Postgrex.INET{address: address, netmask: 64}) ==
               18_446_744_073_709_551_616

      assert count_hosts(%Postgrex.INET{address: address, netmask: 128}) == 1
    end
  end

  describe "host/1" do
    test "ipv4" do
      assert host(%Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24}) == {1, 2, 3, 4}
    end

    test "ipv6" do
      assert host(%Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64}) ==
               {1, 2, 3, 4, 5, 6, 7, 8}
    end
  end

  describe "range/1" do
    test "ipv4" do
      assert range(%Postgrex.INET{address: {1, 2, 3, 4}, netmask: 0}) ==
               {{0, 0, 0, 0}, {255, 255, 255, 255}}

      assert range(%Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24}) ==
               {{1, 2, 3, 0}, {1, 2, 3, 255}}

      assert range(%Postgrex.INET{address: {1, 0, 0, 0}, netmask: 28}) ==
               {{1, 0, 0, 0}, {1, 0, 0, 15}}

      assert range(%Postgrex.INET{address: {1, 2, 3, 4}, netmask: 31}) ==
               {{1, 2, 3, 4}, {1, 2, 3, 5}}

      assert range(%Postgrex.INET{address: {1, 2, 3, 4}, netmask: 32}) ==
               {{1, 2, 3, 4}, {1, 2, 3, 4}}
    end
  end

  describe "contains?/2" do
    test "ipv4" do
      assert contains?(
               %Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24},
               %Postgrex.INET{address: {1, 2, 3, 0}}
             )

      assert contains?(
               %Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24},
               %Postgrex.INET{address: {1, 2, 3, 100}}
             )

      assert contains?(
               %Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24},
               %Postgrex.INET{address: {1, 2, 3, 255}}
             )

      refute contains?(
               %Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24},
               %Postgrex.INET{address: {2, 1, 1, 1}}
             )

      refute contains?(
               %Postgrex.INET{address: {1, 2, 3, 4}, netmask: 24},
               %Postgrex.INET{address: {2, 2, 4, 0}}
             )
    end

    test "ipv6" do
      assert contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 0}}
             )

      assert contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 2, 3, 4, 65_535, 100, 65_535, 65_535}}
             )

      assert contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 2, 3, 4, 65_535, 65_535, 65_535, 65_535}}
             )

      refute contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 2, 3, 5, 0, 0, 0, 0}}
             )

      refute contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 2, 3, 5, 0, 0, 6, 255}}
             )

      refute contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 2, 4, 4, 0, 0, 0, 0}}
             )

      refute contains?(
               %Postgrex.INET{address: {1, 2, 3, 4, 5, 6, 7, 8}, netmask: 64},
               %Postgrex.INET{address: {1, 3, 3, 4, 0, 0, 0, 0}}
             )
    end
  end

  describe "to_string/1" do
    test "persists the host address" do
      {:ok, inet} = cast("10.0.0.5/24")
      assert Kernel.to_string(inet) == "10.0.0.5/24"
    end

    test "formats IPv6 addresses" do
      {:ok, inet} = cast("::0/0")
      assert Kernel.to_string(inet) == "::/0"

      {:ok, inet} = cast("fd00:3:0000::1/64")
      assert Kernel.to_string(inet) == "fd00:3::1/64"
    end
  end
end
