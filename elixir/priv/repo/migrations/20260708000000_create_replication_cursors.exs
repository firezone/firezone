defmodule Portal.Repo.Migrations.CreateReplicationCursors do
  use Ecto.Migration

  def change do
    create table(:replication_cursors, primary_key: false) do
      add(:slot_name, :text, primary_key: true)
      add(:last_lsn, :bigint, null: false, default: 0)

      timestamps()
    end
  end
end
