defmodule Portal.Repo.Migrations.AddLockEnabledAtToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:lock_enabled_at, :utc_datetime_usec, null: true)
    end
  end
end
