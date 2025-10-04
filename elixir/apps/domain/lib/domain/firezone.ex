defmodule Domain.Firezone do
  alias Domain.{
    Auth,
    Accounts,
    Firezone,
    Repo
  }

  def create_directory(attrs, %Accounts.Account{} = account) do
    Firezone.Directory.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def fetch_directory_by_directory_id(%Accounts.Account{} = account, directory_id) do
    Firezone.Directory.Query.all()
    |> Firezone.Directory.Query.by_account_id(account.id)
    |> Firezone.Directory.Query.by_directory_id(directory_id)
    |> Repo.fetch(Firezone.Directory.Query)
  end

  def update_directory(%Firezone.Directory{} = directory, attrs, %Auth.Subject{} = subject) do
    required_permission = Firezone.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Firezone.Directory.Query.all()
      |> Firezone.Directory.Query.by_account_id(subject.account.id)
      |> Firezone.Directory.Query.by_directory_id(directory.directory_id)
      |> Repo.fetch_and_update(Firezone.Directory.Query,
        with: &Firezone.Directory.Changeset.update(&1, attrs)
      )
    end
  end

  def directory_exists?(%Accounts.Account{} = account) do
    Firezone.Directory.Query.all()
    |> Firezone.Directory.Query.by_account_id(account.id)
    |> Repo.exists?()
  end
end
