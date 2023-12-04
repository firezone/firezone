defmodule Domain.Auth.Provider.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Auth.{Subject, Provider}

  @create_fields ~w[id name adapter provisioner adapter_config adapter_state disabled_at]a
  @update_fields ~w[name adapter_config adapter_state provisioner disabled_at deleted_at]a
  @required_fields ~w[name adapter adapter_config provisioner]a

  def create(account, attrs, %Subject{} = subject) do
    account
    |> create(attrs)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def create(%Accounts.Account{} = account, attrs) do
    %Provider{}
    |> cast(attrs, @create_fields)
    |> put_change(:account_id, account.id)
    |> changeset()
    |> put_change(:created_by, :system)
  end

  def update(%Provider{} = provider, attrs) do
    provider
    |> cast(attrs, @update_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> validate_required(:adapter)
    |> unique_constraint(:base,
      name: :auth_providers_account_id_adapter_index,
      message: "this provider is already enabled"
    )
    |> unique_constraint(:base,
      name: :auth_providers_account_id_oidc_adapter_index,
      message: "this provider is already connected"
    )
    |> validate_provisioner()
    |> validate_required(@required_fields)
  end

  defp validate_provisioner(changeset) do
    with false <- has_errors?(changeset, :adapter),
         {_data_or_changes, adapter} <- fetch_field(changeset, :adapter) do
      capabilities = Domain.Auth.Adapters.fetch_capabilities!(adapter)
      provisioners = Keyword.fetch!(capabilities, :provisioners)
      default_provisioner = Keyword.fetch!(capabilities, :default_provisioner)

      changeset
      |> validate_inclusion(:provisioner, provisioners)
      |> put_default_value(:provisioner, default_provisioner)
    else
      _ -> changeset
    end
  end

  def disable_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  def enable_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_change(:disabled_at, nil)
  end

  def delete_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
