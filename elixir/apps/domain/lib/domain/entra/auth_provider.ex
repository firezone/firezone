defmodule Domain.Entra.AuthProvider do
  use Domain, :schema

  schema "entra_auth_providers" do
    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directories.Directory

    field :name, :string
    field :tenant_id, :string
    field :disabled_at, :utc_datetime_usec

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
