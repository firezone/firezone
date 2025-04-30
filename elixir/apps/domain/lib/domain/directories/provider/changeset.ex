defmodule Domain.Directories.Provider.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Directories.Provider
  alias Domain.Directories.Okta

  @create_fields ~w[
    type
    account_id
    auth_provider_id
    sync_state
    disabled_at
  ]a

  def create(%Accounts.Account{} = account, %Auth.Provider{} = auth_provider, attrs) do
    %Provider{}
    |> cast(attrs, @create_fields)
    |> validate_required([:type])
    |> put_change(:account_id, account.id)
    |> put_change(:auth_provider_id, auth_provider.id)
    |> validate_inclusion(:type, Provider.types())
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:type, name: :directory_providers_account_id_type_index)
    |> unique_constraint(:auth_provider_id, name: :directory_providers_auth_provider_id_index)
    |> validate_idp_sync_feature_is_available(account)
    |> maybe_cast_polymorphic_embeds()
  end

  def disable(%Provider{} = provider) do
    provider
    |> cast(%{}, [:disabled_at])
    |> put_change(:disabled_at, DateTime.utc_now())
  end

  def enable(%Provider{} = provider) do
    provider
    |> cast(%{}, [:disabled_at])
    |> put_change(:disabled_at, nil)
  end

  def update_sync_state(%Provider{} = provider, attrs) do
    {sync_state_mod, sync_state_changeset_mod} = sync_state_modules(provider.type)

    provider
    |> cast(attrs, [:sync_state])
    |> cast_polymorphic_embed(:sync_state,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(sync_state_mod, current_attrs, :json)
        |> sync_state_changeset_mod.changeset(attrs)
      end
    )
  end

  defp validate_idp_sync_feature_is_available(changeset, account) do
    if Accounts.idp_sync_enabled?(account) do
      changeset
    else
      changeset
      |> add_error(:base, "IDP sync is not enabled for this account")
    end
  end

  # Only cast embeds if the type is set. Allows a validation error to occur instead
  # of a function clause exception.
  defp maybe_cast_polymorphic_embeds(changeset) do
    if type = get_field(changeset, :type) do
      {sync_state_mod, sync_state_changeset_mod} = sync_state_modules(type)
      {config_mod, config_changeset_mod} = config_modules(type)

      changeset
      |> cast_polymorphic_embed(:sync_state,
        with: fn current_attrs, new_attrs ->
          Ecto.embedded_load(sync_state_mod, current_attrs, :json)
          |> sync_state_changeset_mod.changeset(new_attrs)
        end
      )
    else
      changeset
    end
  end

  defp sync_state_modules(:okta), do: {Okta.SyncState, Okta.SyncState.Changeset}
end
