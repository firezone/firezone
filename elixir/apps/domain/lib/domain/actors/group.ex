defmodule Domain.Actors.Group do
  use Domain, :schema

  schema "actor_groups" do
    field :name, :string
    field :type, Ecto.Enum, values: ~w[managed static]a

    field :directory, :string
    field :idp_id, :string

    # Those fields will be set for groups we synced from IdP's
    belongs_to :provider, Domain.Auth.Provider
    field :provider_identifier, :string

    field :last_synced_at, :utc_datetime_usec

    has_many :policies, Domain.Policies.Policy, foreign_key: :actor_group_id

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete
    field :member_count, :integer, virtual: true

    has_many :actors, through: [:memberships, :actor]

    belongs_to :account, Domain.Accounts.Account

    subject_trail(~w[actor identity provider system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(~w[name type]a)
    |> trim_change(~w[name directory idp_id provider_identifier]a)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :actor_groups_account_id_name_index)
    |> unique_constraint(:base, name: :actor_groups_account_idp_fields_index)
    |> unique_constraint(:base, name: :provider_fields_not_null)
    |> unique_constraint(:base,
      name: :actor_groups_account_id_provider_id_provider_identifier_index
    )
  end
end
