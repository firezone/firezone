defmodule Portal.IPv4AddressFixtures do
  @moduledoc """
  Test helpers for creating IPv4 addresses.
  """

  import Ecto.Changeset
  import Portal.AccountFixtures
  alias Portal.{IPv4Address, Repo}

  def valid_ipv4_address_attrs do
    # Generate unique address using monotonic counter
    offset = System.unique_integer([:positive, :monotonic])
    # Base: 100.64.0.0/11, offset into last two octets
    third = rem(div(offset, 256), 32)
    fourth = rem(offset, 256)
    fourth = if fourth < 2, do: fourth + 2, else: fourth

    %{
      address: %Postgrex.INET{address: {100, 64, third, fourth}}
    }
  end

  @doc """
  Create an IPv4 address for a client or gateway.

  ## Examples

      ipv4 = ipv4_address_fixture(client: client)
      ipv4 = ipv4_address_fixture(gateway: gateway)
      ipv4 = ipv4_address_fixture(client: client, address: %Postgrex.INET{address: {100, 64, 0, 5}})

  """
  def ipv4_address_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    client = Map.get(attrs, :client)
    gateway = Map.get(attrs, :gateway)

    account =
      cond do
        client -> client.account || Repo.preload(client, :account).account
        gateway -> gateway.account || Repo.preload(gateway, :account).account
        true -> Map.get_lazy(attrs, :account, &account_fixture/0)
      end

    address = Map.get_lazy(attrs, :address, fn -> valid_ipv4_address_attrs().address end)

    changeset =
      %IPv4Address{}
      |> change(address: address)
      |> put_assoc(:account, account)

    changeset =
      cond do
        client -> put_assoc(changeset, :client, client)
        gateway -> put_assoc(changeset, :gateway, gateway)
        true -> changeset
      end

    Repo.insert!(changeset)
  end
end
