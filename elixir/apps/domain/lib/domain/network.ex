defmodule Domain.Network do
  alias Domain.Network.Address
  alias __MODULE__.DB

  # Encompasses all of CGNAT and our reserved IPv6 unique local prefix
  @reserved_cidrs %{
    ipv4: %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10},
    ipv6: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, 0, 0}, netmask: 48}
  }

  # For generating new IPs for clients and gateways
  @device_cidrs %{
    ipv4: %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 11},
    ipv6: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, 0, 0}, netmask: 107}
  }

  def reserved_cidrs, do: @reserved_cidrs

  def fetch_next_available_address!(account_id, type, opts \\ []) do
    cidrs = Keyword.get(opts, :cidrs, @device_cidrs)
    cidr = Map.fetch!(cidrs, type)
    hosts = Domain.Types.CIDR.count_hosts(cidr)
    offset = Enum.random(2..max(2, hosts - 2))

    DB.fetch_and_insert_next_address!(account_id, cidr, offset)
  end

  defmodule DB do
    alias Domain.Safe
    alias Domain.Network.Address

    def fetch_and_insert_next_address!(account_id, cidr, offset) do
      {:ok, address} =
        Safe.transact(fn ->
          next_address =
            Address.Query.next_available_address(account_id, cidr, offset)
            |> Safe.unscoped()
            |> Safe.one!()

          next_address
          |> Address.Changeset.create(account_id)
          |> Safe.unscoped()
          |> Safe.insert()
        end)

      address.address
    end
  end
end
