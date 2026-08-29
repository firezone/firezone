defmodule Portal.OAuthAuthorizationCode do
  @moduledoc """
  A single-use authorization code awaiting exchange at the token endpoint.

  The row is deleted the moment it is redeemed, so a replayed code finds
  nothing to match. Codes live for about a minute; anything older is swept.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "oauth_authorization_codes" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor
    belongs_to :oauth_client, Portal.OAuthClient
    belongs_to :oauth_grant, Portal.OAuthGrant

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true
    field :secret_fragment, :string, virtual: true, redact: true

    field :code_challenge, :string
    field :code_challenge_method, :string

    field :redirect_uri, :string
    field :resource, :string
    field :scopes, {:array, :string}, default: []

    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(
      ~w[secret_hash secret_salt code_challenge code_challenge_method redirect_uri resource scopes expires_at]a
    )
    |> validate_inclusion(:code_challenge_method, ["S256"])
    |> validate_length(:code_challenge, min: 43, max: 128)
    |> Portal.Scope.validate(:scopes)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:oauth_client)
    |> assoc_constraint(:oauth_grant)
  end
end
