defmodule Domain.Actors.Group do
  use Domain, :schema

  schema "actor_groups" do
    field :name, :string
    field :type, Ecto.Enum, values: ~w[managed static]a

    # Those fields will be set for groups we synced from IdP's
    belongs_to :provider, Domain.Auth.Provider
    field :provider_identifier, :string

    field :last_synced_at, :utc_datetime_usec

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` column is removed from DB
    has_many :policies, Domain.Policies.Policy,
      foreign_key: :actor_group_id,
      where: [deleted_at: nil]

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete

    # TODO: where doesn't work on join tables so soft-deleted records will be preloaded,
    # ref https://github.com/firezone/firezone/issues/2162
    has_many :actors, through: [:memberships, :actor]

    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directories.Directory

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec

    subject_trail(~w[actor identity provider system]a)
    timestamps()
  end
end
