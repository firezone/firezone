defmodule Domain.Gateways.Group do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          managed_by: :account | :system,
          account_id: Ecto.UUID.t(),
          created_by: :actor | :identity | :system,
          created_by_subject: map(),
          deleted_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "gateway_groups" do
    field :name, :string

    field :managed_by, Ecto.Enum, values: ~w[account system]a

    belongs_to :account, Domain.Accounts.Account
    # TODO: HARD-DELETE - Remove `where` after `deleted_at` column is remove
    has_many :gateways, Domain.Gateways.Gateway, foreign_key: :group_id, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` column is remove
    has_many :tokens, Domain.Tokens.Token,
      foreign_key: :gateway_group_id,
      where: [deleted_at: nil]

    has_many :connections, Domain.Resources.Connection, foreign_key: :gateway_group_id

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
