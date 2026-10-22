defmodule Portal.Repo.Migrations.AddUsersWatchChannelToGoogleDirectories do
  use Ecto.Migration

  def change do
    alter table(:google_directories) do
      add(:webhook_secret, :string)
      add(:users_channel_id, :string)
      add(:users_resource_id, :string)
      add(:channel_expires_at, :timestamptz)
    end
  end
end
