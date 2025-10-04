defmodule Domain.Userpass.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    Userpass.AuthProvider
  }

  @required_fields ~w[account_id directory_id created_by created_by_subject]a

  def create(attrs, %Auth.Subject{} = subject) do
    %AuthProvider{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def update(%AuthProvider{} = auth_provider, attrs) do
    auth_provider
    |> cast(attrs, ~w[disabled_at]a)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint([:account_id],
      name: :userpass_auth_providers_pkey,
      message: "is already configured for this account"
    )
  end
end
