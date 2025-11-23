defmodule Domain.ExternalIdentity do
  use Domain, :schema

  schema "external_identities" do
    belongs_to :actor, Domain.Actors.Actor, on_replace: :update

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

    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directory

    timestamps(updated_at: false)
  end

  def changeset(changeset) do
    changeset
    |> assoc_constraint(:actor)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint(:base, name: :external_identities_account_idp_fields_index)
  end
end
