defmodule Domain.Okta.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "okta_auth_providers" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    belongs_to :directory, Domain.Directories.Directory
    field :org_domain, :string, primary_key: true
    field :client_id, :string
    field :client_secret, :string
    field :disabled_at, :utc_datetime_usec

    subject_trail(~w[actor identity]a)
    timestamps()
  end
end
