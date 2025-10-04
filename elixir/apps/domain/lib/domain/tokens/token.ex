defmodule Domain.Tokens.Token do
  use Domain, :schema

  schema "tokens" do
    field :type, Ecto.Enum,
      values: [
        :browser,
        :client,
        :api_client,
        :relay_group,
        :gateway_group,
        :email
      ]

    field :name, :string

    # set for browser and client tokens, empty for service account tokens
    belongs_to :identity, Domain.Auth.Identity
    # set for browser and client tokens
    belongs_to :actor, Domain.Actors.Actor
    # set for relay tokens
    belongs_to :relay_group, Domain.Relays.Group
    # set for gateway tokens
    belongs_to :gateway_group, Domain.Gateways.Group

    # we store just hash(nonce+fragment+salt)
    field :secret_nonce, :string, virtual: true, redact: true
    field :secret_fragment, :string, virtual: true, redact: true
    field :secret_salt, :string, redact: true
    field :secret_hash, :string, redact: true

    # Limits how many times invalid secret can be used for a token
    field :remaining_attempts, :integer

    belongs_to :account, Domain.Accounts.Account

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_at, :utc_datetime_usec

    # Maybe this is not needed and they should be in the join tables (eg. relay_group_tokens)
    field :created_by_user_agent, :string
    field :created_by_remote_ip, Domain.Types.IP

    field :expires_at, :utc_datetime_usec

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
