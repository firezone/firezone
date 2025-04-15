defmodule Domain.Directories.Provider.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Auth
  alias Domain.Directories.Provider
  alias Domain.Directories.Okta

  @create_fields ~w[
    type
    account_id
    auth_provider_id
    sync_state
  ]a

  @update_fields ~w[
    sync_state
    disabled_at
  ]a

  def create(%Accounts.Account{} = account, %Auth.Provider{} = auth_provider, attrs) do
    sync_state_module = sync_state_module(attrs[:type])

    %Provider{}
    |> cast(attrs, @create_fields)
    |> validate_required(:type)
    |> cast_polymorphic_embed(:sync_state,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(sync_state_module, current_attrs, :json)
        |> Okta.SyncState.Changeset.changeset(attrs)
      end
    )
    |> put_change(:account_id, account.id)
    |> put_change(:auth_provider_id, auth_provider.id)
    |> validate_inclusion(:type, Provider.types())
    |> unique_constraint(:base, name: :directory_providers_account_id_auth_provider_id_index)
    |> unique_constraint(:base, name: :directory_providers_account_id_type_index)
    |> validate_idp_sync_feature_is_available(account)
  end

  def update(%Provider{} = provider, attrs) do
    sync_state_module = sync_state_module(provider.type)

    provider
    |> cast(attrs, @update_fields)
    |> cast_polymorphic_embed(:sync_state,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(sync_state_module, current_attrs, :json)
        |> Okta.SyncState.Changeset.changeset(attrs)
      end
    )
    |> validate_idp_sync_feature_is_available(provider.account)
  end

  defp validate_idp_sync_feature_is_available(changeset, account) do
    if Accounts.idp_sync_enabled?(account) do
      changeset
    else
      changeset
      |> add_error(:base, "IDP sync is not enabled for this account")
    end
  end

  defp sync_state_module(:okta), do: Okta.SyncState
end
