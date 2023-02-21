defmodule FzHttp.Devices.Device.QueryTest do
  use FzHttp.DataCase, async: true
  import FzHttp.Devices.Device.Query
  alias FzHttp.DevicesFixtures

  describe "next_available_address/3" do
    test "selects available IPv4 in CIDR range at the offset" do
      cidr = string_to_cidr("10.3.2.0/29")
      gateway_ip = string_to_ip("10.3.2.0")
      offset = 3

      queryable = next_available_address(cidr, offset, [gateway_ip])

      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 2, 3}}
    end

    test "skips addresses taken by the gateway" do
      cidr = string_to_cidr("10.3.3.0/29")
      gateway_ip = string_to_ip("10.3.3.3")
      offset = 3

      queryable = next_available_address(cidr, offset, [gateway_ip])

      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 3, 4}}
    end

    test "forward scans available address after offset it it's assigned to a device" do
      cidr = string_to_cidr("10.3.4.0/29")
      gateway_ip = string_to_ip("10.3.4.0")
      offset = 3

      queryable = next_available_address(cidr, offset, [gateway_ip])

      DevicesFixtures.device(%{ipv4: "10.3.4.3"})
      DevicesFixtures.device(%{ipv4: "10.3.4.4"})
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 4, 5}}

      DevicesFixtures.device(%{ipv4: "10.3.4.5"})
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 4, 6}}
    end

    test "backward scans available address if forward scan found not available IPs" do
      cidr = string_to_cidr("10.3.5.0/29")
      gateway_ip = string_to_ip("10.3.5.0")
      offset = 5

      queryable = next_available_address(cidr, offset, [gateway_ip])

      DevicesFixtures.device(%{ipv4: "10.3.5.5"})
      DevicesFixtures.device(%{ipv4: "10.3.5.6"})
      # Notice: end of range is 10.3.5.7
      # but it's a broadcast address that we don't allow to assign
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 5, 4}}

      DevicesFixtures.device(%{ipv4: "10.3.5.4"})
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 5, 3}}
    end

    test "selects nothing when CIDR range is exhausted" do
      cidr = string_to_cidr("10.3.6.0/30")
      gateway_ip = string_to_ip("10.3.6.1")
      offset = 1

      DevicesFixtures.device(%{ipv4: "10.3.6.2"})
      queryable = next_available_address(cidr, offset, [gateway_ip])
      assert is_nil(Repo.one(queryable))

      DevicesFixtures.device(%{ipv4: "10.3.6.1"})
      queryable = next_available_address(cidr, offset, [])
      assert is_nil(Repo.one(queryable))

      # Notice: real start of range is 10.3.6.0,
      # but it's a typical gateway address that we don't allow to assign
    end

    test "prevents two concurrent transactions from acquiring the same address" do
      cidr = string_to_cidr("10.3.7.0/29")
      gateway_ip = string_to_ip("10.3.7.3")
      offset = 3

      queryable = next_available_address(cidr, offset, [gateway_ip])

      test_pid = self()

      spawn(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            ip = Repo.one(queryable)
            send(test_pid, {:ip, ip})
            Process.sleep(200)
          end)
        end)
      end)

      ip1 = Repo.one(queryable)
      assert_receive {:ip, ip2}, 1_000

      assert Enum.sort([ip1, ip2]) ==
               Enum.sort([
                 %Postgrex.INET{address: {10, 3, 7, 4}},
                 %Postgrex.INET{address: {10, 3, 7, 5}}
               ])
    end

    test "selects available IPv6 in CIDR range at the offset" do
      cidr = string_to_cidr("fd00::3:3:0/120")
      gateway_ip = string_to_ip("fd00::3:3:3")
      offset = 3

      queryable = next_available_address(cidr, offset, [gateway_ip])

      assert Repo.one(queryable) == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 3, 4}}
    end

    test "selects available IPv6 at end of CIDR range" do
      cidr = string_to_cidr("fd00::/106")
      gateway_ip = string_to_ip("fd00::3:3:3")
      offset = 4_194_304

      queryable = next_available_address(cidr, offset, [gateway_ip])

      assert Repo.one(queryable) == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 63, 65_535}}
    end

    test "works when offset is out of IPv6 CIDR range" do
      cidr = string_to_cidr("fd00::/106")
      gateway_ip = string_to_ip("fd00::3:3:3")
      offset = 4_194_305

      queryable = next_available_address(cidr, offset, [gateway_ip])

      assert Repo.one(queryable) == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 64, 0}}
    end

    test "works when netmask allows a large number of devices" do
      cidr = string_to_cidr("fd00::/70")
      gateway_ip = string_to_ip("fd00::3:3:3")
      offset = 9_223_372_036_854_775_807

      queryable = next_available_address(cidr, offset, [gateway_ip])

      assert Repo.one(queryable) == %Postgrex.INET{
               address: {64_768, 0, 0, 0, 32_767, 65_535, 65_535, 65_534}
             }
    end

    test "selects nothing when IPv6 CIDR range is exhausted" do
      cidr = string_to_cidr("fd00::3:2:0/126")
      gateway_ip = string_to_ip("fd00::3:2:1")
      offset = 3

      DevicesFixtures.device(%{ipv6: "fd00::3:2:2"})

      queryable = next_available_address(cidr, offset, [gateway_ip])
      assert is_nil(Repo.one(queryable))
    end
  end

  defp string_to_cidr(string) do
    {:ok, inet} = FzHttp.Types.CIDR.cast(string)
    inet
  end

  defp string_to_ip(string) do
    {:ok, inet} = FzHttp.Types.IP.cast(string)
    inet
  end
end
