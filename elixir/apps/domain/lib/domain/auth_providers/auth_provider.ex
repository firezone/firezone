defmodule Domain.AuthProviders.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "auth_providers" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    field :id, :binary_id, primary_key: true

    has_one :email_otp_auth_provider, Domain.EmailOTP.AuthProvider,
      references: :id,
      foreign_key: :id

    has_one :userpass_auth_provider, Domain.Userpass.AuthProvider,
      references: :id,
      foreign_key: :id

    has_one :google_auth_provider, Domain.Google.AuthProvider, references: :id, foreign_key: :id
    has_one :okta_auth_provider, Domain.Okta.AuthProvider, references: :id, foreign_key: :id
    has_one :entra_auth_provider, Domain.Entra.AuthProvider, references: :id, foreign_key: :id
    has_one :oidc_auth_provider, Domain.OIDC.AuthProvider, references: :id, foreign_key: :id
  end
end
