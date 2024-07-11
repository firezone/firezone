defmodule Domain.Network do
  alias Domain.Repo
  alias Domain.Network.Address

  # Encompasses all CIDR and DNS Resource addresses
  @reserved_cidrs %{
    ipv4: %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10},
    ipv6: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, 0, 0}, netmask: 48}
  }

  # For generating new IPs for CIDR/IP Resources
  @resource_cidrs %{
    ipv4: %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 11},
    ipv6: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, 0, 0}, netmask: 107}
  }

  def resource_cidrs, do: @resource_cidrs

  def reserved_cidrs, do: @reserved_cidrs

  def fetch_next_available_address!(account_id, type, opts \\ []) do
    unless Repo.in_transaction?() do
      raise "fetch_next_available_address/1 must be called inside a transaction"
    end

    cidrs = Keyword.get(opts, :cidrs, @resource_cidrs)
    cidr = Map.fetch!(cidrs, type)
    hosts = Domain.Types.CIDR.count_hosts(cidr)
    offset = Enum.random(2..max(2, hosts - 2))

    address =
      Address.Query.next_available_address(account_id, cidr, offset)
      |> Domain.Repo.one!()
      |> Address.Changeset.create(account_id)
      |> Repo.insert!()

    address.address
  end
end
