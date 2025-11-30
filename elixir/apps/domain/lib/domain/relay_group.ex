defmodule Domain.RelayGroup do
  use Domain, :schema

  schema "relay_groups" do
    field :name, :string

    belongs_to :account, Domain.Account
    has_many :relays, Domain.Relays.Relay, foreign_key: :group_id
    has_many :tokens, Domain.Tokens.Token, foreign_key: :relay_group_id

    timestamps()
  end

  def changeset(changeset) do
    import Ecto.Changeset
    import Domain.Repo.Changeset

    changeset
    |> trim_change(~w[name]a)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_required(~w[name]a)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :relay_groups_name_index)
    |> unique_constraint(:name, name: :relay_groups_account_id_name_index)
  end
end
