defmodule Domain.Accounts do
  alias Domain.Repo
  alias Domain.Accounts.Account

  def create_account(attrs) do
    Account.Changeset.create_changeset(attrs)
    |> Repo.insert()
  end
end
