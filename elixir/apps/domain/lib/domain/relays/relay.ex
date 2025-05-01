defmodule Domain.Relays.Relay do
  use Domain, :schema

  schema "relays" do
    field :name, :string

    field :ipv4, Domain.Types.IP
    field :ipv6, Domain.Types.IP

    field :port, :integer, default: 3478

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_version, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :last_used_token, Domain.Tokens.Token

    field :stamp_secret, :string, virtual: true

    field :online?, :boolean, virtual: true

    belongs_to :account, Domain.Accounts.Account
    belongs_to :group, Domain.Relays.Group

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
