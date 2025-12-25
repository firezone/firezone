defmodule Portal.Repo.Migrations.MovePkeyToLsnOnChangeLogs do
  use Ecto.Migration

  def up do
    alter table(:change_logs) do
      remove(:id)
    end

    drop(index(:change_logs, [:lsn]))

    execute("ALTER TABLE change_logs ADD PRIMARY KEY (lsn)")
  end

  def down do
    execute("ALTER TABLE change_logs DROP CONSTRAINT change_logs_pkey")

    alter table(:change_logs) do
      add(:id, :uuid, default: fragment("gen_random_uuid()"), primary_key: true)
    end

    create(index(:change_logs, [:lsn]))
  end
end
