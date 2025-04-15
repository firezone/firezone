defmodule Domain.Directories do
  alias Domain.Repo
  alias Domain.Directories.Provider
  alias Domain.Accounts
  alias Domain.Auth

  def fetch_provider_by_id(id) do
    Provider.Query.all()
    |> Provider.Query.by_id(id)
    |> Repo.fetch(Provider.Query)
  end

  def create_provider(%Accounts.Account{} = account, %Auth.Provider{} = auth_provider, attrs) do
    Provider.Changeset.create(account, auth_provider, attrs)
    |> Repo.insert()
  end

  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.Changeset.update(attrs)
    |> Repo.update()
  end
end
