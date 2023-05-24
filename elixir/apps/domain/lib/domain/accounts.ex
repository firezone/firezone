defmodule Domain.Accounts do
  alias Domain.Repo
  alias Domain.Auth
  alias Domain.Accounts.Account

  def create_account(attrs) do
    Account.Changeset.create_changeset(attrs)
    |> Repo.insert()
  end

  def ensure_has_access_to(%Auth.Subject{} = subject, %Account{} = account) do
    if subject.account.id == account.id do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end
