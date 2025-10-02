defmodule Domain.Entra.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "entra_auth_providers" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    belongs_to :directory, Domain.Directories.Directory
    field :tenant_id, :string, primary_key: true
    field :disabled_at, :utc_datetime_usec

    subject_trail(~w[actor identity]a)
    timestamps()
  end
end
