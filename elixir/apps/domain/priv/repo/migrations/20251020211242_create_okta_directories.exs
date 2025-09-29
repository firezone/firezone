defmodule Domain.Repo.Migrations.CreateOktaDirectories do
  use Domain, :migration

  def change do
    create table(:okta_directories, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      account()
      add(:org_domain, :string, null: false)

      add(:issuer, :text, null: false)
      add(:client_id, :string)
      add(:client_secret, :string)

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

    create(index(:okta_directories, [:account_id, :org_domain], unique: true))
    create(index(:okta_directories, [:account_id, :issuer], unique: true))
    create(index(:okta_directories, [:account_id, :name], unique: true))
  end
end
