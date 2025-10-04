defmodule Domain.Identities.Identity do
  use Domain, :schema

  schema "auth_identities" do
    belongs_to :account, Domain.Accounts.Account
    belongs_to :actor, Domain.Actors.Actor, on_replace: :update
    belongs_to :directory, Domain.Directories.Directory

    field :email, :string
    field :provider_identifier, :string

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_at, :utc_datetime_usec

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
