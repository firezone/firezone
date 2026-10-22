defmodule Portal.OAuthToken do
  @moduledoc """
  An issued OAuth access token, with the refresh secret that renews it.

  `resource` is the audience the token was minted for. It is checked on every
  request, so a token issued for one resource cannot be replayed against
  another even while it is otherwise valid.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "oauth_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor
    belongs_to :oauth_grant, Portal.OAuthGrant

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true
    field :secret_fragment, :string, virtual: true, redact: true

    field :refresh_secret_hash, :string, redact: true
    field :refresh_secret_salt, :string, redact: true
    field :refresh_secret_fragment, :string, virtual: true, redact: true

    field :scopes, {:array, :string}, default: []
    field :resource, :string

    field :expires_at, :utc_datetime_usec
    field :refresh_expires_at, :utc_datetime_usec

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Portal.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[secret_hash secret_salt scopes resource expires_at]a)
    |> Portal.Scope.validate(:scopes)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:oauth_grant)
  end
end
