defmodule Portal.Repo.Migrations.AddScheduledDeletionAtToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:scheduled_deletion_at, :utc_datetime_usec, null: true)
    end
  end
end
