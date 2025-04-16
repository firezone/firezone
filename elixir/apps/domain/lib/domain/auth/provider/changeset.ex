defmodule Domain.Auth.Provider.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Auth.{Subject, Provider, Adapters}

  @create_fields ~w[id name adapter provisioner adapter_config adapter_state disabled_at]a
  @update_fields ~w[name adapter_config
                    last_syncs_failed last_sync_error sync_disabled_at sync_error_emailed_at
                    adapter_state provisioner disabled_at deleted_at]a
  @required_fields ~w[name adapter adapter_config provisioner]a

  def create(account, attrs, %Subject{} = subject) do
    account
    |> create(attrs)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def create(%Accounts.Account{} = account, attrs) do
    all_adapters = Adapters.list_all_adapters!()

    allowed_adapters =
      if Accounts.idp_sync_enabled?(account) do
        all_adapters
      else
        Enum.reject(all_adapters, fn adapter ->
          capabilities = Adapters.fetch_capabilities!(adapter)
          capabilities[:default_provisioner] == :custom
        end)
      end

    %Provider{}
    |> cast(attrs, @create_fields)
    |> put_change(:account_id, account.id)
    |> changeset()
    |> validate_inclusion(:adapter, allowed_adapters)
    |> put_change(:created_by, :system)
  end

  def update(%Provider{} = provider, attrs) do
    provider
    |> cast(attrs, @update_fields)
    |> changeset()
  end

  def sync_finished(%Provider{} = provider) do
    provider
    |> change()
    |> put_change(:last_synced_at, DateTime.utc_now())
    |> put_change(:last_syncs_failed, 0)
    |> put_change(:sync_disabled_at, nil)
    |> put_change(:sync_error_emailed_at, nil)
  end

  def sync_failed(%Provider{} = provider, error) do
    last_syncs_failed = provider.last_syncs_failed || 0

    provider
    |> change()
    |> put_change(:last_synced_at, nil)
    |> put_change(:last_sync_error, error)
    |> put_change(:last_syncs_failed, last_syncs_failed + 1)
  end

  def sync_error_emailed(%Provider{} = provider) do
    provider
    |> change()
    |> put_change(:sync_error_emailed_at, DateTime.utc_now())
  end

  def sync_requires_manual_intervention(%Provider{} = provider, error) do
    sync_failed(provider, error)
    |> put_change(:sync_disabled_at, DateTime.utc_now())
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
