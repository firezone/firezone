defmodule Domain.Repo.Migrations.CreateEntraDirectories do
  use Domain, :migration

  def change do
    create table(:entra_directories, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      account()
      add(:tenant_id, :string, null: false)

      add(:name, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:current_job_id, :integer)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:entra_directories, [:account_id, :tenant_id], unique: true))
    create(index(:entra_directories, [:account_id, :name], unique: true))
  end
end
