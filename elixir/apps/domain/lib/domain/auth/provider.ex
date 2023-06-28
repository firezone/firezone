defmodule Domain.Auth.Provider do
  use Domain, :schema

  schema "auth_providers" do
    field :name, :string

    field :adapter, Ecto.Enum, values: ~w[email openid_connect userpass token]a
    field :adapter_config, :map

    belongs_to :account, Domain.Accounts.Account

    has_many :groups, Domain.Actors.Group

    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
