defmodule Domain.Directories.Provider do
  use Domain, :schema

  @types ~w[
    okta
  ]a

  schema "directory_providers" do
    belongs_to :account, Domain.Accounts.Account

    field :type, Ecto.Enum, values: @types
    field :sync_state, :map
    field :config, :map, redact: true
    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  def types do
    @types
  end
end
