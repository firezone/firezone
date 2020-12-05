defmodule FgHttp.Repo.Migrations.AddLastSeenAtToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add :last_seen_at, :utc_datetime_usec
    end
  end
end
