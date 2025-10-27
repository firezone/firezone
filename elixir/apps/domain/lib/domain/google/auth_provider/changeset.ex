defmodule Domain.Google.AuthProvider.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    AuthProviders,
    Google
  }

  @required_fields ~w[name context issuer]a
  @fields @required_fields ++ ~w[disabled_at hosted_domain verified_at assigned_default_at]a

  def new do
    %Google.AuthProvider{}
    |> cast(%{}, @fields)
  end

  def create(
        %Google.AuthProvider{} = auth_provider \\ %Google.AuthProvider{},
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

  def update(%Google.AuthProvider{} = auth_provider, attrs) do
    auth_provider
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:hosted_domain, min: 1, max: 255)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:hosted_domain,
      name: :google_auth_providers_account_id_issuer_hosted_domain_index,
      message: "An authentication provider for this hosted domain already exists."
    )
    |> unique_constraint(:name,
      name: :google_auth_providers_account_id_name_index,
      message: "An authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :google_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :google_auth_providers_auth_provider_id_fkey
    )
  end
end
