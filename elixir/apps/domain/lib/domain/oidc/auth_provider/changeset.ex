defmodule Domain.OIDC.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    OIDC.AuthProvider
  }

  @required_fields ~w(account_id directory_id client_id client_secret created_by created_by_subject)a

  def create(attrs, %Auth.Subject{} = subject) do
    %AuthProvider{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def update(%AuthProvider{} = auth_provider, attrs) do
    auth_provider
    |> cast(attrs, ~w(client_id client_secret directory_id disabled_at)a)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint([:account_id, :client_id],
      message: "is already configured for this account and client ID"
    )
  end
end
