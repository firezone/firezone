defmodule Domain.Directories.Directory do
  use Domain, :schema

  @primary_key false
  schema "directories" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    field :id, Ecto.UUID, primary_key: true
    field :type, Ecto.Enum, values: [:firezone, :google, :entra, :okta]

    has_one :google_directory, Domain.Google.Directory, references: :id, where: [type: :google]

    has_one :google_auth_provider, Domain.Google.AuthProvider,
      references: :id,
      where: [type: :google]

    has_one :entra_directory, Domain.Entra.Directory, references: :id, where: [type: :entra]

    has_one :entra_auth_provider, Domain.Entra.AuthProvider,
      references: :id,
      where: [type: :entra]

    has_one :okta_directory, Domain.Okta.Directory, references: :id, where: [type: :okta]
    has_one :okta_auth_provider, Domain.Okta.AuthProvider, references: :id, where: [type: :okta]

    has_many :oidc_auth_providers, Domain.OIDC.AuthProvider, references: :id

    has_one :email_auth_provider, Domain.Email.AuthProvider,
      references: :id,
      where: [type: :firezone]

    has_one :userpass_auth_provider, Domain.Userpass.AuthProvider,
      references: :id,
      where: [type: :firezone]

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
