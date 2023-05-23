defmodule Domain.Actors.Actor do
  use Domain, :schema

  schema "actors" do
    field :type, Ecto.Enum, values: [:end_user, :account_admin_user, :service_account]

    # TODO:
    # field :first_name, :string
    # field :last_name, :string

    has_many :identities, Domain.Auth.Identity

    # belongs_to :group, Domain.Actors.Group
    belongs_to :account, Domain.Accounts.Account

    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
