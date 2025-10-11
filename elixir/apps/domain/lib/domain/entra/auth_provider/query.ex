defmodule Domain.Entra.AuthProvider.Query do
  use Domain, :query

  def all do
    from(providers in Domain.Entra.AuthProvider, as: :providers)
  end

  def not_disabled(queryable \\ all()) do
    join(
      queryable,
      :inner,
      [providers: providers],
      auth_providers in Domain.AuthProviders.AuthProvider,
      as: :auth_providers,
      on:
        providers.account_id == auth_providers.account_id and
          providers.auth_provider_id == auth_providers.id
    )
    |> where([auth_providers: auth_providers], is_nil(auth_providers.disabled_at))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end

  def by_auth_provider_id(querable, auth_provider_id) do
    where(querable, [providers: providers], providers.auth_provider_id == ^auth_provider_id)
  end

  def by_tenant_id(queryable, tenant_id) do
    where(queryable, [providers: providers], providers.tenant_id == ^tenant_id)
  end
end
