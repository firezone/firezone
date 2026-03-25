defmodule Portal.Repo.Migrations.AddKeyUniqueIndexToAccounts do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      unique_index(:accounts, [:key], name: :accounts_key_index, concurrently: true)
    )
  end
end
