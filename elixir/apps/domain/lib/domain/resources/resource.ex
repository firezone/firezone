defmodule Domain.Resources.Resource do
  use Domain, :schema

  @type filter :: %{
          protocol: :tcp | :udp | :icmp,
          ports: [Domain.Types.Int4Range.t()]
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          address: String.t(),
          address_description: String.t() | nil,
          name: String.t(),
          type: :cidr | :ip | :dns | :internet,
          ip_stack: :ipv4_only | :ipv6_only | :dual,
          filters: [filter()],
          account_id: Ecto.UUID.t(),
          created_by: String.t(),
          created_by_subject: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "resources" do
    field :address, :string
    field :address_description, :string
    field :name, :string

    field :type, Ecto.Enum, values: [:cidr, :ip, :dns, :internet]
    field :ip_stack, Ecto.Enum, values: [:ipv4_only, :ipv6_only, :dual]

    embeds_many :filters, Filter, on_replace: :delete, primary_key: false do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1]
      field :ports, {:array, Domain.Types.Int4Range}, default: []
    end

    belongs_to :account, Domain.Accounts.Account
    has_many :connections, Domain.Resources.Connection, on_replace: :delete
    has_many :gateway_groups, through: [:connections, :gateway_group]

    has_many :policies, Domain.Policies.Policy
    has_many :actor_groups, through: [:policies, :actor_group]

    # Warning: do not do Repo.preload/2 for this field, it will not work intentionally,
    # because the actual preload query should also use joins and process policy conditions
    has_many :authorized_by_policies, Domain.Policies.Policy, where: [id: {:fragment, "FALSE"}]

    field :created_by, Ecto.Enum, values: ~w[identity actor system]a
    field :created_by_subject, :map

    timestamps()
  end
end
