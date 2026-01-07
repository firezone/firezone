defmodule Portal.IPv6AddressFixtures do
  @moduledoc """
  Test helpers for creating IPv6 addresses.
  """

  import Ecto.Changeset
  import Portal.AccountFixtures
  alias Portal.{IPv6Address, Repo}

  def valid_ipv6_address_attrs do
    # Generate unique address using monotonic counter
    offset = System.unique_integer([:positive, :monotonic])
    # Base: fd00:2021:1111::/107
    # Last two words can vary
    w7 = rem(div(offset, 65536), 65536)
    w8 = rem(offset, 65536)
    w8 = if w8 < 2, do: w8 + 2, else: w8

    %{
      address: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, w7, w8}}
    }
  end

  @doc """
  Create an IPv6 address for a client or gateway.

  ## Examples

      ipv6 = ipv6_address_fixture(client: client)
      ipv6 = ipv6_address_fixture(gateway: gateway)
      ipv6 = ipv6_address_fixture(client: client, address: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, 0, 5}})

  """
  def ipv6_address_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    client = Map.get(attrs, :client)
    gateway = Map.get(attrs, :gateway)

    account =
      cond do
        client -> client.account || Repo.preload(client, :account).account
        gateway -> gateway.account || Repo.preload(gateway, :account).account
        true -> Map.get_lazy(attrs, :account, &account_fixture/0)
      end

    address = Map.get_lazy(attrs, :address, fn -> valid_ipv6_address_attrs().address end)

    changeset =
      %IPv6Address{}
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
