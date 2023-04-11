defmodule Domain.Network do
  alias Domain.Repo
  alias Domain.Network.Address

  @cidrs %{
    ipv4: %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10},
    ipv6: %Postgrex.INET{address: {64768, 0, 0, 0, 0, 0, 0, 0}, netmask: 106}
  }

  def fetch_next_available_address!(type) do
    unless Repo.in_transaction?() do
      raise "fetch_next_available_address/1 must be called inside a transaction"
    end

    cidr = Map.fetch!(@cidrs, type)
    hosts = Domain.Types.CIDR.count_hosts(cidr)
    offset = Enum.random(2..(hosts - 2))

    address =
      Address.Query.next_available_address(cidr, offset)
      |> Domain.Repo.one!()
      |> Address.Changeset.create_changeset()
      |> Repo.insert!()

    address.address
  end
end
