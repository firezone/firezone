defmodule Domain.Repo.Migrations.CreateEntraDirectories do
  use Domain, :migration

  def change do
    create table(:entra_directories, primary_key: false) do
      account(primary_key: true)
      add(:tenant_id, :string, null: false, primary_key: true)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:entra_directories, [:account_id, :issuer], unique: true))
    create(index(:entra_directories, [:account_id, :name], unique: true))
  end
end
