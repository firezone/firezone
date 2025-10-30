defmodule Domain.OIDC.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    AuthProviders
  }

  @required_fields ~w[name context client_id client_secret discovery_document_uri issuer is_verified]a
  @fields @required_fields ++ ~w[is_disabled]a

  def create(
        auth_provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> put_subject_trail(:created_by, subject)
    |> put_change(:account_id, subject.account.id)
    |> build_auth_provider_assoc(subject.account.id)
    |> changeset()
  end

  def update(auth_provider, attrs) do
    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 255)
    |> validate_uri(:discovery_document_uri)
    |> validate_length(:discovery_document_uri, min: 1, max: 2000)
    |> validate_length(:issuer, min: 1, max: 2000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:client_id,
      name: :oidc_auth_providers_account_id_client_id_index,
      message: "An OIDC authentication provider with this client_id already exists."
    )
    |> unique_constraint(:name,
      name: :oidc_auth_providers_account_id_name_index,
      message: "An OIDC authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :oidc_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :oidc_auth_providers_auth_provider_id_fkey
    )
  end

  defp build_auth_provider_assoc(changeset, account_id) do
    id = get_field(changeset, :id) || Ecto.UUID.generate()

    changeset
    |> put_change(:id, id)
    |> put_assoc(:auth_provider, %AuthProviders.AuthProvider{
      id: id,
      account_id: account_id
    })
  end
end
