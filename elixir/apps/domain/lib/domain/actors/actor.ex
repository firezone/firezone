defmodule Domain.Actors.Actor do
  use Domain, :schema

  schema "actors" do
    field :type, Ecto.Enum,
      values: [:account_user, :account_admin_user, :service_account, :api_client]

    field :email, :string

    # TODO: IdP refactor
    # Move this to auth_identities
    field :name, :string

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from DB
    has_many :identities, Domain.Auth.Identity, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from DB
    has_many :clients, Domain.Clients.Client,
      where: [deleted_at: nil],
      preload_order: [desc: :last_seen_at]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from DB
    has_many :tokens, Domain.Tokens.Token, where: [deleted_at: nil]

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete
    # TODO: where doesn't work on join tables so soft-deleted records will be preloaded,
    # ref https://github.com/firezone/firezone/issues/2162
    has_many :groups, through: [:memberships, :group]

    belongs_to :account, Domain.Accounts.Account

    field :last_seen_at, :utc_datetime_usec, virtual: true
    field :last_synced_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
