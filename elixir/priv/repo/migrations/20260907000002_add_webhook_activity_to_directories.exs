defmodule Portal.Repo.Migrations.AddWebhookActivityToDirectories do
  use Ecto.Migration

  def change do
    alter table(:okta_directories) do
      add(:webhook_verified_at, :timestamptz)
      add(:webhook_received_at, :timestamptz)
    end

    alter table(:entra_directories) do
      add(:webhook_received_at, :timestamptz)
    end

    alter table(:google_directories) do
      add(:webhook_received_at, :timestamptz)
    end
  end
end
