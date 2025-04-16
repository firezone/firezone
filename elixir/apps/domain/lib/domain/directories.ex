defmodule Domain.Directories do
  alias Domain.Repo
  alias Domain.Directories.Provider
  alias Domain.Accounts

  # TODO: Authorizer

  def fetch_provider_by_id(id) do
    Provider.Query.all()
    |> Provider.Query.by_id(id)
    |> Repo.fetch(Provider.Query)
  end

  def fetch_provider_by_account_and_type(%Accounts.Account{} = account, type) do
    Provider.Query.all()
    |> Provider.Query.by_account(account)
    |> Provider.Query.by_type(type)
    |> Repo.fetch(Provider.Query)
  end

  def list_providers_for_account(%Accounts.Account{} = account) do
    Provider.Query.all()
    |> Provider.Query.not_disabled()
    |> Provider.Query.by_account(account)
    |> Repo.list(Provider.Query)
  end

  def create_provider(%Accounts.Account{} = account, attrs) do
    Provider.Changeset.create(account, attrs)
    |> Repo.insert()
  end

  def disable_provider(%Provider{} = provider) do
    provider
    |> Provider.Changeset.disable()
    |> Repo.update()
  end

  def enable_provider(%Provider{} = provider) do
    provider
    |> Provider.Changeset.enable()
    |> Repo.update()
  end

  def update_provider_config(%Provider{} = provider, attrs) do
    provider
    |> Provider.Changeset.update_config(attrs)
    |> Repo.update()
  end

  def update_provider_sync_state(%Provider{} = provider, attrs) do
    provider
    |> Provider.Changeset.update_sync_state(attrs)
    |> Repo.update()
  end

  def delete_provider(%Provider{} = provider) do
    Repo.delete(provider)
  end
end
