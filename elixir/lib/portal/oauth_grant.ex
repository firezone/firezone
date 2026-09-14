defmodule Portal.OAuthGrant do
  @moduledoc """
  One actor's standing consent for one OAuth client.

  Kept apart from the tokens it backs so that it is what the person sees and
  revokes in the portal: the tokens come and go as the client refreshes, and
  deleting the grant takes every one of them with it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "oauth_grants" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor
    belongs_to :oauth_client, Portal.OAuthClient

    field :scopes, {:array, :string}, default: []

    has_many :tokens, Portal.OAuthToken, references: :id, foreign_key: :oauth_grant_id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[scopes]a)
    |> Portal.Scope.validate(:scopes)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:oauth_client)
    |> unique_constraint([:account_id, :actor_id, :oauth_client_id],
      name: :oauth_grants_account_id_actor_id_oauth_client_id_index
    )
  end
end
