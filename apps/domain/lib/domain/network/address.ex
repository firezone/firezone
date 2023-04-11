defmodule Domain.Network.Address do
  use Domain, :schema

  @primary_key {:address, Domain.Types.IP, []}
  schema "network_addresses" do
    field :type, Ecto.Enum, values: [:ipv4, :ipv6]
  end
end
