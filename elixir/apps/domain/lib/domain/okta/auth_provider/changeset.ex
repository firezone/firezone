defmodule Domain.Okta.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    AuthProviders,
    Okta
  }

  @required_fields ~w[name context org_domain client_id client_secret issuer]a
  @fields @required_fields ++ ~w[disabled_at]a

  def create(
        %Okta.AuthProvider{} = auth_provider \\ %Okta.AuthProvider{},
        attrs,
        %Auth.Subject{} = subject
      ) do
    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> put_subject_trail(:created_by, subject)
    |> put_change(:account_id, subject.account.id)
    |> put_assoc(:auth_provider, %AuthProviders.AuthProvider{account_id: subject.account.id})
    |> changeset()
  end

  def update(%Okta.AuthProvider{} = auth_provider, attrs) do
    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:org_domain, min: 1, max: 255)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:issuer, name: :okta_auth_providers_account_id_issuer_index)
    |> unique_constraint(:name, name: :okta_auth_providers_account_id_name_index)
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :okta_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :okta_auth_providers_auth_provider_id_fkey
    )
  end
end
