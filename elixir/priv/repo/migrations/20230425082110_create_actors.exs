defmodule Portal.Repo.Migrations.CreateActors do
  use Ecto.Migration

  def change do
    create table(:actors, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:type, :string, null: false)
      add(:role, :string, null: false)

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:disabled_at, :utc_datetime_usec)
      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
