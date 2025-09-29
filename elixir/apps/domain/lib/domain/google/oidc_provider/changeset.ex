defmodule Domain.Google.OIDCProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    Google.OIDCProvider
  }

  @fields ~w(account_id hosted_domain created_by created_by_subject)a

  def create(attrs, %Auth.Subject{} = subject) do
    %OIDCProvider{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def update(%OIDCProvider{} = oidc_provider, attrs) do
    oidc_provider
    |> cast(attrs, ~w[hosted_domain]a)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@fields)
    |> validate_length(:hosted_domain, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> unique_constraint([:account_id, :hosted_domain],
      name: :google_oidc_providers_pkey,
      message: "Google is already configured for this account"
    )
  end
end
