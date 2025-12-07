defmodule Domain.NetworkAddressFixtures do
  @moduledoc """
  Test helpers for creating network addresses and related data.
  """

  import Domain.AccountFixtures

  @doc """
  Generate valid network address attributes with sensible defaults.
  """
  def valid_network_address_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      address: generate_ipv4_address(unique_num),
      type: :ipv4
    })
  end

  @doc """
  Generate a network address with valid default attributes.

  The network address will be created with an associated account unless one is provided.

  ## Examples

      network_address = network_address_fixture()
      network_address = network_address_fixture(account: account)
      network_address = network_address_fixture(type: :ipv6)

  """
  def network_address_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build network address attrs
    network_address_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_network_address_attrs()

    # Generate appropriate address based on type
    network_address_attrs =
      if Map.get(network_address_attrs, :type) == :ipv6 && !Map.has_key?(attrs, :address) do
        unique_num = System.unique_integer([:positive, :monotonic])
        Map.put(network_address_attrs, :address, generate_ipv6_address(unique_num))
      else
        network_address_attrs
      end

    {:ok, network_address} =
      %Domain.Network.Address{}
      |> Ecto.Changeset.cast(network_address_attrs, [:address, :type])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Repo.insert()

    network_address
  end

  @doc """
  Generate an IPv4 network address.
  """
  def ipv4_network_address_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:type, :ipv4)

    network_address_fixture(attrs)
  end

  @doc """
  Generate an IPv6 network address.
  """
  def ipv6_network_address_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:type, :ipv6)

    network_address_fixture(attrs)
  end

  # Private helpers

  defp generate_ipv4_address(unique_num) do
    # Generate a unique IPv4 address in the 10.0.0.0/8 private range
    # Use unique_num to ensure uniqueness across test runs
    octet2 = rem(div(unique_num, 65536), 256)
    octet3 = rem(div(unique_num, 256), 256)
    octet4 = rem(unique_num, 256)

    "10.#{octet2}.#{octet3}.#{octet4}"
  end

  defp generate_ipv6_address(unique_num) do
    # Generate a unique IPv6 address in the fd00::/8 private range
    # Use unique_num to create a unique address
    hex = Integer.to_string(unique_num, 16) |> String.pad_leading(8, "0")

    "fd00::#{String.slice(hex, 0, 4)}:#{String.slice(hex, 4, 4)}"
  end
end
