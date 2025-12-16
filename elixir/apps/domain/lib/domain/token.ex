defmodule Domain.Token do
  use Ecto.Schema
  import Ecto.Changeset
  import Domain.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tokens" do
    belongs_to :account, Domain.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :type, Ecto.Enum, values: [:client]

    field :name, :string

    # track which auth provider was used to authenticate
    belongs_to :auth_provider, Domain.AuthProvider

    # set for browser and client tokens
    belongs_to :actor, Domain.Actor

    # we store just hash(nonce+fragment+salt)
    field :secret_nonce, :string, virtual: true, redact: true
    field :secret_fragment, :string, virtual: true, redact: true
    field :secret_salt, :string, redact: true
    field :secret_hash, :string, redact: true

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
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:auth_provider)
    |> check_constraint(:type, name: :type_must_be_valid)
    |> unique_constraint(:secret_hash)
  end
end
