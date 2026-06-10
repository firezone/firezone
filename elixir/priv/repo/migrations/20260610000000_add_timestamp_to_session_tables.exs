defmodule Portal.Repo.Migrations.AddTimestampToSessionTables do
  use Ecto.Migration

  # Captures the moment the session connected. `inserted_at` lags behind the
  # actual connect time by however long the entry sits in `Portal.Queue`
  # before being flushed, so it cannot be used as the session start time.
  # Nullable because rows written before this release have no recorded
  # connect time.
  def change do
    alter table(:client_sessions) do
      add(:timestamp, :timestamptz)
    end

    alter table(:gateway_sessions) do
      add(:timestamp, :timestamptz)
    end

    alter table(:portal_sessions) do
      add(:timestamp, :timestamptz)
    end
  end
end
