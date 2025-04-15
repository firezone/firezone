defmodule Domain.Directories.Provider do
  use Domain, :schema

  @types ~w[
    okta
  ]a

  schema "directory_providers" do
    belongs_to :account, Domain.Accounts.Account
    belongs_to :auth_provider, Domain.Auth.Provider

    field :type, Ecto.Enum, values: @types

    field :sync_state, :map

    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  def types do
    @types
  end
end
