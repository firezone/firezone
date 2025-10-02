defmodule Domain.Firezone do
  alias Domain.{
    Accounts,
    Firezone,
    Repo
  }

  def create_directory(attrs, %Accounts.Account{} = account) do
    Firezone.Directory.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def fetch_directory_by_id(%Accounts.Account{} = account, id) do
    Firezone.Directory.Query.all()
    |> Firezone.Directory.Query.by_account_id(account.id)
    |> Firezone.Directory.Query.by_id(id)
    |> Repo.fetch(Firezone.Directory.Query)
  end
end
