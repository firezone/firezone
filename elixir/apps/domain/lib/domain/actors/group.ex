defmodule Domain.Actors.Group do
  use Domain, :schema

  schema "actor_groups" do
    field :name, :string
    field :type, Ecto.Enum, values: ~w[managed static]a

    # Those fields will be set for groups we synced from IdP's
    belongs_to :provider, Domain.Auth.Provider
    field :provider_identifier, :string

    field :last_synced_at, :utc_datetime_usec

    has_many :policies, Domain.Policies.Policy, foreign_key: :actor_group_id

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete

    has_many :actors, through: [:memberships, :actor]

    field :created_by, Ecto.Enum, values: ~w[actor identity provider system]a
    field :created_by_subject, :map

    belongs_to :account, Domain.Accounts.Account

    timestamps()
  end
end
