defmodule Domain.Resources.Resource do
  use Domain, :schema

  schema "resources" do
    field :address, :string
    field :address_description, :string
    field :name, :string

    field :type, Ecto.Enum, values: [:cidr, :ip, :dns]

    embeds_many :filters, Filter, on_replace: :delete, primary_key: false do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1, all: -1]
      field :ports, {:array, Domain.Types.Int4Range}, default: []
    end

    belongs_to :account, Domain.Accounts.Account
    has_many :connections, Domain.Resources.Connection, on_replace: :delete
    # TODO: where doesn't work on join tables so soft-deleted records will be preloaded,
    # ref https://github.com/firezone/firezone/issues/2162
    has_many :gateway_groups, through: [:connections, :gateway_group]

    has_many :policies, Domain.Policies.Policy, where: [deleted_at: nil]
    has_many :actor_groups, through: [:policies, :actor_group]
    field :authorized_by_policy, :map, virtual: true

    field :created_by, Ecto.Enum, values: ~w[identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
