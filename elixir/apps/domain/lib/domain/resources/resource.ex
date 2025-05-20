defmodule Domain.Resources.Resource do
  use Domain, :schema

  schema "resources" do
    field :persistent_id, Ecto.UUID

    field :address, :string
    field :address_description, :string
    field :name, :string

    field :type, Ecto.Enum, values: [:cidr, :ip, :dns, :internet]

    embeds_many :filters, Filter, on_replace: :delete, primary_key: false do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1]
      field :ports, {:array, Domain.Types.Int4Range}, default: []
    end

    belongs_to :account, Domain.Accounts.Account
    has_many :connections, Domain.Resources.Connection, on_replace: :delete
    # TODO: where doesn't work on join tables so soft-deleted records will be preloaded,
    # ref https://github.com/firezone/firezone/issues/2162
    has_many :gateway_groups, through: [:connections, :gateway_group]

    has_many :policies, Domain.Policies.Policy, where: [deleted_at: nil]
    has_many :actor_groups, through: [:policies, :actor_group]

    # Warning: do not do Repo.preload/2 for this field, it will not work intentionally,
    # because the actual preload query should also use joins and process policy conditions
    has_many :authorized_by_policies, Domain.Policies.Policy, where: [id: {:fragment, "FALSE"}]

    field :created_by, Ecto.Enum, values: ~w[identity actor system]a
    field :created_by_subject, :map
    belongs_to :created_by_actor, Domain.Actors.Actor
    belongs_to :created_by_identity, Domain.Auth.Identity

    belongs_to :replaced_by_resource, Domain.Resources.Resource
    has_one :replaces_resource, Domain.Resources.Resource, foreign_key: :replaced_by_resource_id

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
