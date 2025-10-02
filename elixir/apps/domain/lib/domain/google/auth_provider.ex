defmodule Domain.Google.AuthProvider do
  use Domain, :schema

  schema "google_auth_providers" do
    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directories.Directory

    field :name, :string
    field :hosted_domain, :string
    field :disabled_at, :utc_datetime_usec

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
