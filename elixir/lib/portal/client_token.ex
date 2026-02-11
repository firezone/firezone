defmodule Portal.ClientToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "client_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor

    has_many :client_sessions, Portal.ClientSession, references: :id

    belongs_to :auth_provider, Portal.AuthProvider

    # we store just hash(nonce+fragment+salt)
    field :secret_nonce, :string, virtual: true, redact: true
    field :secret_fragment, :string, virtual: true, redact: true
    field :secret_salt, :string, redact: true
    field :secret_hash, :string, redact: true

    field :latest_session, :any, virtual: true

    field :expires_at, :utc_datetime_usec

    # Allows for convenient mapping of the corresponding auth provider for display
    field :auth_provider_name, :string, virtual: true
    field :auth_provider_type, :string, virtual: true

    # Virtual field for online status (populated via Presence)
    field :online?, :boolean, virtual: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:auth_provider)
  end
end
