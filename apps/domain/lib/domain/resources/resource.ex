defmodule Domain.Resources.Resource do
  use Domain, :schema

  schema "resources" do
    field :address, :string
    field :name, :string

    embeds_many :filters, Filter, on_replace: :delete do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1, all: -1]
      field :ports, {:array, Domain.Types.Int4Range}, default: []
    end
    
    field :ipv4, Domain.Types.IP
    field :ipv6, Domain.Types.IP

    belongs_to :account, Domain.Accounts.Account
    has_many :connections, Domain.Resources.Connection, on_replace: :delete
    has_many :gateways, through: [:connections, :gateway]

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
