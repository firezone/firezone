defmodule Domain.Auth.Identity do
  use Domain, :schema

  schema "auth_identities" do
    belongs_to :actor, Domain.Actors.Actor, on_replace: :update
    belongs_to :provider, Domain.Auth.Provider

    field :email, :string
    field :provider_identifier, :string

    # TODO: IdP sync
    # Remove these field after all customers have migrated to the new sync
    field :provider_state, :map, redact: true
    field :provider_virtual_state, :map, virtual: true, redact: true

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directories.Directory

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :clients, Domain.Clients.Client, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :tokens, Domain.Tokens.Token, foreign_key: :identity_id, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec

    subject_trail(~w[system provider identity]a)
    timestamps(updated_at: false)
  end
end
