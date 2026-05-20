defmodule Portal.PendingIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "pending_identities" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true

    belongs_to :actor, Portal.Actor
    belongs_to :auth_provider, Portal.AuthProvider
    belongs_to :one_time_passcode, Portal.OneTimePasscode

    field :issuer, :string
    field :idp_id, :string

    field :email, :string
    field :name, :string
    field :given_name, :string
    field :family_name, :string
    field :middle_name, :string
    field :nickname, :string
    field :preferred_username, :string
    field :profile, :string
    field :picture, :string

    belongs_to :directory, Portal.Directory

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :id,
      :account_id,
      :actor_id,
      :auth_provider_id,
      :one_time_passcode_id,
      :issuer,
      :idp_id,
      :email,
      :name
    ])
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:auth_provider)
    |> assoc_constraint(:one_time_passcode)
    |> assoc_constraint(:directory)
  end
end
