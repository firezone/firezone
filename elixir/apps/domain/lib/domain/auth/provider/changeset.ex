defmodule Domain.Auth.Provider.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Auth.{Subject, Provider}

  @fields ~w[name adapter adapter_config]a
  @required_fields @fields

  def create_changeset(account, attrs, %Subject{} = subject) do
    account
    |> create_changeset(attrs)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def create_changeset(%Accounts.Account{} = account, attrs) do
    %Provider{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account.id)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_required(@required_fields)
    |> unique_constraint(:adapter,
      name: :auth_providers_account_id_adapter_index,
      message: "this provider is already enabled"
    )
    |> unique_constraint(:adapter,
      name: :auth_providers_account_id_oidc_adapter_index,
      message: "this provider is already connected"
    )
    |> put_change(:created_by, :system)
  end

  def disable_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  def enable_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:disabled_at, nil)
  end

  def delete_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
