defmodule Domain.Auth.Identity do
  use Domain, :schema

  schema "auth_identities" do
    belongs_to :actor, Domain.Actors.Actor, on_replace: :update

    # Identity Provider fields
    field :issuer
    field :directory
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

    field :last_synced_at, :utc_datetime_usec

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

  def changeset(changeset) do
    changeset
    |> assoc_constraint(:actor)
    |> assoc_constraint(:account)
    |> unique_constraint(:account_id,
      name: :auth_identities_account_idp_fields_index,
      message: "An identity with this issuer and IDP ID already exists for this account."
    )
    |> check_constraint(:issuer, name: :issuer_idp_id_integrity)
  end
end
