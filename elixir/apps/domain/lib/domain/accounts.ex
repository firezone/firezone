defmodule Domain.Accounts do
  alias Domain.{Repo, Validator}
  alias Domain.Auth
  alias Domain.Accounts.{Authorizer, Account}

  def fetch_account_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_accounts_permission()),
         true <- Validator.valid_uuid?(id) do
      Account.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

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
