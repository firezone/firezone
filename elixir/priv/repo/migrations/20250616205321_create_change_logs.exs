defmodule Portal.Repo.Migrations.CreateChangeLogs do
  use Ecto.Migration

  def up do
    create table(:change_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:lsn, :bigint, null: false)
      add(:table, :string, null: false)
      add(:op, :string, null: false)
      add(:old_data, :map)
      add(:data, :map)
      add(:vsn, :integer, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # For pulling logs for a particular customer
    create(index(:change_logs, [:account_id]))

    # For truncating logs by date
    create(index(:change_logs, [:inserted_at]))
  end

  def down do
    drop(table(:change_logs))
  end
end
