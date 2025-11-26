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

    # track which auth provider was used to authenticate
    belongs_to :auth_provider, Domain.AuthProvider

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

    field :expires_at, :utc_datetime_usec

    field :auth_provider_name, :string, virtual: true
    field :auth_provider_type, :string, virtual: true

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_length(:name, max: 255)
    |> trim_change(:name)
    |> put_change(:secret_salt, Domain.Crypto.random_token(16))
    |> validate_format(:secret_nonce, ~r/^[^\.]{0,128}$/)
    |> validate_required(:secret_fragment)
    |> put_hash(:secret_fragment, :sha3_256,
      with_nonce: :secret_nonce,
      with_salt: :secret_salt,
      to: :secret_hash
    )
    |> delete_change(:secret_nonce)
    |> validate_required(~w[secret_salt secret_hash]a)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:auth_provider)
    |> assoc_constraint(:relay_group)
    |> assoc_constraint(:gateway_group)
    |> unique_constraint(:secret_hash)
  end
end
