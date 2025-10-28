defmodule Domain.Userpass.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    AuthProviders,
    Userpass
  }

  @required_fields ~w[context name]a
  @fields @required_fields ++ ~w[disabled_at]a

  def create(
        %Userpass.AuthProvider{} = auth_provider \\ %Userpass.AuthProvider{},
        attrs,
        %Auth.Subject{} = subject
      ) do
    id = Ecto.UUID.generate()

    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> put_subject_trail(:created_by, subject)
    |> put_change(:account_id, subject.account.id)
    |> put_change(:id, id)
    |> put_assoc(:auth_provider, %AuthProviders.AuthProvider{
      id: id,
      account_id: subject.account.id
    })
    |> changeset()
  end

  def update(%Userpass.AuthProvider{} = auth_provider, attrs) do
    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:account_id,
      name: :userpass_auth_providers_pkey,
      message: "An authentication provider for this account already exists."
    )
    |> unique_constraint(:name,
      name: :userpass_auth_providers_account_id_name_index,
      message: "An authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> check_constraint(:issuer, name: :issuer_must_be_firezone)
    |> foreign_key_constraint(:account_id, name: :userpass_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :userpass_auth_providers_auth_provider_id_fkey
    )
  end
end
