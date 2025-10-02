defmodule Domain.Email.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "email_auth_providers" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    belongs_to :directory, Domain.Directories.Directory

    field :disabled_at, :utc_datetime_usec

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
