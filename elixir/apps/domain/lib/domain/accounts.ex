defmodule Domain.Accounts do
  alias Domain.{Repo, Validator}
  alias Domain.Auth
  alias Domain.Accounts.Account

  def fetch_account_by_id(id) do
    if Validator.valid_uuid?(id) do
      Account.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

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
