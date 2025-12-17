defmodule Portal.IPv4AddressTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ClientFixtures
  alias Portal.IPv4Address
  alias Portal.Repo

  describe "allocate_next_available_address/2" do
    setup do
      account = account_fixture()
      %{account: account}
    end

    test "returns sequential IPv4 addresses for different clients", %{account: account} do
      # Create clients without addresses
      client1 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
      client2 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
      client3 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)

      Repo.transaction(fn ->
        {:ok, addr1} =
          IPv4Address.allocate_next_available_address(account.id, client_id: client1.id)

        {:ok, addr2} =
          IPv4Address.allocate_next_available_address(account.id, client_id: client2.id)

        {:ok, addr3} =
          IPv4Address.allocate_next_available_address(account.id, client_id: client3.id)

        # Addresses should be sequential (offset 1, 2, 3 from base)
        assert %Postgrex.INET{address: {100, 64, 0, 1}, netmask: nil} = addr1.address
        assert %Postgrex.INET{address: {100, 64, 0, 2}, netmask: nil} = addr2.address
        assert %Postgrex.INET{address: {100, 64, 0, 3}, netmask: nil} = addr3.address
      end)
    end

    test "different accounts get independent address spaces", %{account: account1} do
      account2 = account_fixture()

      client1 = client_fixture(account: account1, ipv4_address: nil, ipv6_address: nil)
      client2 = client_fixture(account: account2, ipv4_address: nil, ipv6_address: nil)

      Repo.transaction(fn ->
        {:ok, addr1_acc1} =
          IPv4Address.allocate_next_available_address(account1.id, client_id: client1.id)

        {:ok, addr1_acc2} =
          IPv4Address.allocate_next_available_address(account2.id, client_id: client2.id)

        # Both accounts should get the same first address (offset 1)
        assert %Postgrex.INET{address: {100, 64, 0, 1}, netmask: nil} = addr1_acc1.address
        assert %Postgrex.INET{address: {100, 64, 0, 1}, netmask: nil} = addr1_acc2.address
      end)
    end

    test "records addresses in ipv4_addresses table", %{account: account} do
      client = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)

      Repo.transaction(fn ->
        {:ok, addr} =
          IPv4Address.allocate_next_available_address(account.id, client_id: client.id)

        # Verify the address was recorded
        assert Repo.get_by(IPv4Address, account_id: account.id, address: addr.address)
      end)
    end

    test "uses custom CIDR when provided", %{account: account} do
      client = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
      # Use a different CIDR range (10.0.0.0/30 gives addresses 10.0.0.1 to 10.0.0.2)
      custom_cidr = %Postgrex.INET{address: {10, 0, 0, 0}, netmask: 30}

      Repo.transaction(fn ->
        {:ok, addr} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client.id,
            cidr: custom_cidr
          )

        # Should get address from custom CIDR
        assert %Postgrex.INET{address: {10, 0, 0, 1}, netmask: nil} = addr.address
      end)
    end
  end

  describe "allocate_next_available_address/2 boundary conditions" do
    setup do
      account = account_fixture()
      %{account: account}
    end

    test "exhausts address pool and returns error", %{account: account} do
      # /30 gives 4 IPs total: network (.0), 2 usable (.1, .2), broadcast (.3)
      # The allocator skips .0 (base) and .3 (broadcast-1), so only .1 and .2 are available
      small_cidr = %Postgrex.INET{address: {10, 99, 0, 0}, netmask: 30}

      client1 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
      client2 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
      client3 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)

      Repo.transaction(fn ->
        # First allocation should succeed
        {:ok, addr1} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client1.id,
            cidr: small_cidr
          )

        assert %Postgrex.INET{address: {10, 99, 0, 1}, netmask: nil} = addr1.address

        # Second allocation should succeed
        {:ok, addr2} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client2.id,
            cidr: small_cidr
          )

        assert %Postgrex.INET{address: {10, 99, 0, 2}, netmask: nil} = addr2.address

        # Third allocation should fail - pool exhausted (53400 = configuration_limit_exceeded)
        {:error,
         %Postgrex.Error{postgres: %{code: :configuration_limit_exceeded, message: message}}} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client3.id,
            cidr: small_cidr
          )

        assert message =~ "Address pool exhausted"
      end)
    end

    test "wraps around when reaching end of CIDR range", %{account: account} do
      # Use /29 which gives 6 usable addresses (.1 through .6)
      small_cidr = %Postgrex.INET{address: {10, 100, 0, 0}, netmask: 29}

      # Create clients
      clients =
        for _ <- 1..4 do
          client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
        end

      Repo.transaction(fn ->
        # Allocate first 4 addresses
        addrs =
          for client <- clients do
            {:ok, addr} =
              IPv4Address.allocate_next_available_address(account.id,
                client_id: client.id,
                cidr: small_cidr
              )

            addr
          end

        # Should get sequential addresses .1 through .4
        assert %Postgrex.INET{address: {10, 100, 0, 1}} = Enum.at(addrs, 0).address
        assert %Postgrex.INET{address: {10, 100, 0, 2}} = Enum.at(addrs, 1).address
        assert %Postgrex.INET{address: {10, 100, 0, 3}} = Enum.at(addrs, 2).address
        assert %Postgrex.INET{address: {10, 100, 0, 4}} = Enum.at(addrs, 3).address

        # Delete the second address to create a gap
        Repo.delete_all(
          from(a in IPv4Address,
            where: a.account_id == ^account.id and a.address == ^Enum.at(addrs, 1).address
          )
        )

        # Now allocate two more - first should get .5, then wrap to .2 (the gap)
        client5 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)
        client6 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)

        {:ok, addr5} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client5.id,
            cidr: small_cidr
          )

        {:ok, addr6} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client6.id,
            cidr: small_cidr
          )

        # .5 is next after .4
        assert %Postgrex.INET{address: {10, 100, 0, 5}} = addr5.address
        # .6 is next after .5
        assert %Postgrex.INET{address: {10, 100, 0, 6}} = addr6.address

        # Now create one more client to test wrap-around finding the gap at .2
        client7 = client_fixture(account: account, ipv4_address: nil, ipv6_address: nil)

        {:ok, addr7} =
          IPv4Address.allocate_next_available_address(account.id,
            client_id: client7.id,
            cidr: small_cidr
          )

        # Should wrap around and find .2 (the gap we created)
        assert %Postgrex.INET{address: {10, 100, 0, 2}} = addr7.address
      end)
    end
  end

  describe "reserved_cidr/0" do
    test "returns reserved CIDR range" do
      assert %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10} = IPv4Address.reserved_cidr()
    end
  end

  describe "device_cidr/0" do
    test "returns device CIDR range" do
      assert %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 11} = IPv4Address.device_cidr()
    end
  end
end
