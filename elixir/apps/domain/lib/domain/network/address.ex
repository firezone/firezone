defmodule Domain.Network.Address do
  use Domain, :schema

  @primary_key false
  schema "network_addresses" do
    field :address, Domain.Types.IP, primary_key: true
    belongs_to :account, Domain.Accounts.Account, primary_key: true

    field :type, Ecto.Enum, values: [:ipv4, :ipv6]

    timestamps(updated_at: false)
  end
end
