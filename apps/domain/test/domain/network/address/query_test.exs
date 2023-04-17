defmodule Domain.Network.Address.QueryTest do
  use Domain.DataCase, async: true
  import Domain.Network.Address.Query
  alias Domain.{AccountsFixtures, NetworkFixtures}

  setup do
    account = AccountsFixtures.create_account()
    %{account: account}
  end

  describe "next_available_address/3" do
    test "selects available IPv4 in CIDR range at the offset", %{account: account} do
      cidr = string_to_cidr("10.3.2.0/29")
      offset = 3

      queryable = next_available_address(account.id, cidr, offset)

      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 2, 3}}
    end

    test "skips addresses that are already taken for an account", %{account: account} do
      cidr = string_to_cidr("10.3.3.0/29")
      offset = 3

      queryable = next_available_address(account.id, cidr, offset)
      NetworkFixtures.create_address(account: account, address: "10.3.3.3")

      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 3, 4}}
    end

    test "addresses are unique per account", %{account: account} do
      cidr = string_to_cidr("10.3.3.0/29")
      offset = 3

      queryable = next_available_address(account.id, cidr, offset)
      NetworkFixtures.create_address(address: "10.3.3.3")

      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 3, 3}}
    end

    test "forward scans available address after offset it it's assigned to a device", %{
      account: account
    } do
      cidr = string_to_cidr("10.3.4.0/29")
      offset = 3

      queryable = next_available_address(account.id, cidr, offset)

      NetworkFixtures.create_address(account: account, address: "10.3.4.3")
      NetworkFixtures.create_address(account: account, address: "10.3.4.4")
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 4, 5}}

      NetworkFixtures.create_address(account: account, address: "10.3.4.5")
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 4, 6}}
    end

    test "backward scans available address if forward scan found not available IPs", %{
      account: account
    } do
      cidr = string_to_cidr("10.3.5.0/29")
      offset = 5

      queryable = next_available_address(account.id, cidr, offset)

      NetworkFixtures.create_address(account: account, address: "10.3.5.5")
      NetworkFixtures.create_address(account: account, address: "10.3.5.6")
      # Notice: end of range is 10.3.5.7
      # but it's a broadcast address that we don't allow to assign
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 5, 4}}

      NetworkFixtures.create_address(account: account, address: "10.3.5.4")
      assert Repo.one(queryable) == %Postgrex.INET{address: {10, 3, 5, 3}}
    end

    test "selects nothing when CIDR range is exhausted", %{account: account} do
      cidr = string_to_cidr("10.3.6.0/30")
      offset = 1

      NetworkFixtures.create_address(account: account, address: "10.3.6.1")
      NetworkFixtures.create_address(account: account, address: "10.3.6.2")
      queryable = next_available_address(account.id, cidr, offset)
      assert is_nil(Repo.one(queryable))

      # Notice: real start of range is 10.3.6.0,
      # but it's a typical gateway address that we don't allow to assign
    end

    test "prevents two concurrent transactions from acquiring the same address", %{
      account: account
    } do
      cidr = string_to_cidr("10.3.7.0/29")
      offset = 3

      queryable = next_available_address(account.id, cidr, offset)

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
                 %Postgrex.INET{address: {10, 3, 7, 3}},
                 %Postgrex.INET{address: {10, 3, 7, 4}}
               ])
    end

    test "selects available IPv6 in CIDR range at the offset", %{account: account} do
      cidr = string_to_cidr("fd00::3:3:0/120")
      offset = 3

      queryable = next_available_address(account.id, cidr, offset)

      assert Repo.one(queryable) == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 3, 3}}
    end

    test "selects available IPv6 at end of CIDR range", %{account: account} do
      cidr = string_to_cidr("fd00::/106")
      offset = 4_194_304

      queryable = next_available_address(account.id, cidr, offset)

      assert Repo.one(queryable) == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 63, 65_535}}
    end

    test "works when offset is out of IPv6 CIDR range", %{account: account} do
      cidr = string_to_cidr("fd00::/106")
      offset = 4_194_305

      queryable = next_available_address(account.id, cidr, offset)

      assert Repo.one(queryable) == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 64, 0}}
    end

    test "works when netmask allows a large number of devices", %{account: account} do
      cidr = string_to_cidr("fd00::/70")
      offset = 9_223_372_036_854_775_807

      queryable = next_available_address(account.id, cidr, offset)

      assert Repo.one(queryable) == %Postgrex.INET{
               address: {64_768, 0, 0, 0, 32_767, 65_535, 65_535, 65_534}
             }
    end

    test "selects nothing when IPv6 CIDR range is exhausted", %{account: account} do
      cidr = string_to_cidr("fd00::3:2:0/126")
      offset = 3

      NetworkFixtures.create_address(account: account, address: "fd00::3:2:2")

      queryable = next_available_address(account.id, cidr, offset)
      assert is_nil(Repo.one(queryable))
    end
  end

  defp string_to_cidr(string) do
    {:ok, inet} = Domain.Types.CIDR.cast(string)
    inet
  end
end
