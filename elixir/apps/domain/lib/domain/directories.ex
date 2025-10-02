defmodule Domain.Directories do
  alias Domain.{
    Accounts,
    Auth,
    Directories,
    Repo
  }

  def create_directory(attrs, %Accounts.Account{} = account) do
    Directories.Directory.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Directories.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Directories.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def list_directories_for_account(%Accounts.Account{} = account, opts \\ []) do
    Directories.Directory.Query.all()
    |> Directories.Directory.Query.by_account_id(account.id)
    |> Repo.all(opts)
  end
end
