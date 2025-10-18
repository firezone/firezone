defmodule Domain.AuthProviders.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "auth_providers" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    field :id, :binary_id, primary_key: true, read_after_writes: true

    has_one :email_auth_provider, Domain.Email.AuthProvider, references: :id
    has_one :userpass_auth_provider, Domain.Userpass.AuthProvider, references: :id
    has_one :google_auth_provider, Domain.Google.AuthProvider, references: :id
    has_one :okta_auth_provider, Domain.Okta.AuthProvider, references: :id
    has_one :entra_auth_provider, Domain.Entra.AuthProvider, references: :id
    has_one :oidc_auth_provider, Domain.OIDC.AuthProvider, references: :id
  end
end
