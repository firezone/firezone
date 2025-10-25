defmodule Domain.Auth.Identity do
  use Domain, :schema

  schema "auth_identities" do
    belongs_to :actor, Domain.Actors.Actor, on_replace: :update
    belongs_to :provider, Domain.Auth.Provider

    # Unique identifiers
    field :email, :string
    field :provider_identifier, :string

    # Identity Provider fields
    field :issuer
    field :idp_id, :string

    # For Userpass
    field :password_hash, :string, redact: true

    # Optional profile fields
    field :name, :string
    field :given_name, :string
    field :family_name, :string
    field :middle_name, :string
    field :nickname, :string
    field :preferred_username, :string
    field :profile, :string
    field :picture, :string

    # For hosting the picture internally
    field :firezone_avatar_url, :string

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

    has_many :clients, Domain.Clients.Client

    has_many :tokens, Domain.Tokens.Token, foreign_key: :identity_id

    subject_trail(~w[system provider identity]a)
    timestamps(updated_at: false)
  end
end
