defmodule Domain.Clients.Client do
  use Domain, :schema

  schema "clients" do
    field :external_id, :string

    field :name, :string

    field :public_key, :string

    field :ipv4, Domain.Types.IP
    field :ipv6, Domain.Types.IP

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    field :online?, :boolean, virtual: true

    belongs_to :account, Domain.Accounts.Account
    belongs_to :actor, Domain.Actors.Actor
    belongs_to :identity, Domain.Auth.Identity
    belongs_to :last_used_token, Domain.Tokens.Token

    # Hardware Identifiers
    field :device_serial, :string
    field :device_uuid, :string
    field :identifier_for_vendor, :string
    field :firebase_installation_id, :string

    # Verification
    field :verified_at, :utc_datetime_usec
    field :verified_by, Ecto.Enum, values: [:system, :actor, :identity]
    belongs_to :verified_by_actor, Domain.Actors.Actor
    belongs_to :verified_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
