defmodule Domain.Resources.Resource do
  use Domain, :schema

  schema "resources" do
    field :address, :string
    field :name, :string

    field :type, Ecto.Enum, values: [:cidr, :dns]

    embeds_many :filters, Filter, on_replace: :delete do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1, all: -1]
      field :ports, {:array, Domain.Types.Int4Range}, default: []
    end

    field :ipv4, Domain.Types.IP
    field :ipv6, Domain.Types.IP

    belongs_to :account, Domain.Accounts.Account
    has_many :connections, Domain.Resources.Connection, on_replace: :delete
    has_many :gateway_groups, through: [:connections, :gateway_group]

    field :created_by, Ecto.Enum, values: ~w[identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
