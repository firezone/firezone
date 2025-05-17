defmodule Domain.Auth.Identity do
  use Domain, :schema

  schema "auth_identities" do
    belongs_to :actor, Domain.Actors.Actor, on_replace: :update
    belongs_to :provider, Domain.Auth.Provider

    field :email, :string
    field :provider_identifier, :string
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

    field :created_by, Ecto.Enum, values: ~w[system provider identity]a
    field :created_by_subject, :map
    belongs_to :created_by_identity, Domain.Auth.Identity
    belongs_to :created_by_actor, Domain.Actors.Actor

    has_many :clients, Domain.Clients.Client, where: [deleted_at: nil]

    has_many :tokens, Domain.Tokens.Token, foreign_key: :identity_id, where: [deleted_at: nil]

    field :deleted_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
