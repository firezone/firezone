defmodule Domain.Google.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    Google.AuthProvider
  }

  @required_fields ~w(account_id directory_id hosted_domain created_by created_by_subject)a

  def create(attrs, %Auth.Subject{} = subject) do
    %AuthProvider{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def update(%AuthProvider{} = auth_provider, attrs) do
    auth_provider
    |> cast(attrs, ~w[hosted_domain disabled_at]a)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> validate_length(:hosted_domain, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint([:account_id, :hosted_domain],
      name: :google_auth_providers_pkey,
      message: "is already configured for this account and Google Workspace domain"
    )
  end
end
