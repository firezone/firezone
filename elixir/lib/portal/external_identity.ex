defmodule Portal.ExternalIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "external_identities" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor

    # Identity Provider fields
    field :issuer
    field :idp_id, :string

    # Optional profile fields
    field :email, :string
    field :name, :string
    field :given_name, :string
    field :family_name, :string
    field :middle_name, :string
    field :nickname, :string
    field :preferred_username, :string
    field :profile, :string
    field :picture, :string

    # For hosting the picture internally
    field :firezone_avatar_url, :string

    field :last_synced_at, :utc_datetime_usec

    field :directory_name, :string, virtual: true

    belongs_to :directory, Portal.Directory

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:actor)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint(:base, name: :external_identities_account_idp_fields_index)
  end
end
