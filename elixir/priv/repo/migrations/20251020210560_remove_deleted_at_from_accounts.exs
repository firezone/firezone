defmodule Portal.Repo.Migrations.RemoveDeletedAtFromAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
