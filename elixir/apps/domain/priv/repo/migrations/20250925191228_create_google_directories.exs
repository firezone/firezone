defmodule Domain.Repo.Migrations.CreateGoogleDirectories do
  use Domain, :migration

  def change do
    create table(:google_directories, primary_key: false) do
      account(primary_key: true)
      add(:hosted_domain, :string, null: false, primary_key: true)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)
      add(:superadmin_email, :string)
      add(:superadmin_emailed_at, :utc_datetime_usec)
      add(:impersonation_email, :string)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:google_directories, [:account_id, :issuer, :hosted_domain], unique: true))
    create(index(:google_directories, [:account_id, :name], unique: true))
  end
end
