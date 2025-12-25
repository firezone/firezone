defmodule Portal.Repo.Migrations.AddSyncErrorEmailToProvider do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:sync_error_emailed_at, :utc_datetime_usec)
    end
  end
end
