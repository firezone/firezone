defmodule Domain.Actors.Group do
  use Domain, :schema

  schema "actor_groups" do
    field :name, :string

    # Those fields will be set for groups we synced from IdP's
    belongs_to :provider, Domain.Auth.Provider
    field :provider_identifier, :string

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete
    has_many :actors, through: [:memberships, :actor], where: [deleted_at: nil]

    belongs_to :account, Domain.Accounts.Account

    field :created_by, Ecto.Enum, values: ~w[identity provider]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
