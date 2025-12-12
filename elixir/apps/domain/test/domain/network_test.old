defmodule Domain.NetworkTest do
  use Domain.DataCase, async: true
  import Domain.Network

  describe "fetch_next_available_address!/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "raises when called outside of transaction", %{account: account} do
      message = "fetch_next_available_address/1 must be called inside a transaction"

      assert_raise RuntimeError, message, fn ->
        fetch_next_available_address!(account.id, :ipv4)
      end
    end

    test "raises when CIDR range is exhausted", %{account: account} do
      cidrs = %{
        test: %Postgrex.INET{address: {101, 64, 0, 0}, netmask: 32}
      }

      Repo.transaction(fn ->
        assert_raise Ecto.NoResultsError, fn ->
          fetch_next_available_address!(account.id, :test, cidrs: cidrs)
        end
      end)
    end

    test "returns next available IPv4 address", %{account: account} do
      cidrs = %{
        test: %Postgrex.INET{address: {102, 64, 0, 0}, netmask: 30}
      }

      Repo.transaction(fn ->
        assert %Postgrex.INET{address: {102, 64, 0, last}, netmask: nil} =
                 fetch_next_available_address!(account.id, :test, cidrs: cidrs)

        assert last in 1..2
      end)
    end
  end
end
