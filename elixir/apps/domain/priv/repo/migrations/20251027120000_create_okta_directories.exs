defmodule Domain.Repo.Migrations.CreateOktaDirectories do
  use Domain, :migration

  def change do
    create table(:okta_directories, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)
      account()

      add(:client_id, :string)
      add(:private_key_jwk, :jsonb)
      add(:kid, :string)
      add(:okta_domain, :string, null: false)

      add(:name, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)
      add(:is_verified, :boolean, default: false, null: false)

      subject_trail()
      timestamps()
    end

    create(
      index(:okta_directories, [:account_id, :okta_domain],
        name: :okta_directories_account_id_okta_domain_index,
        unique: true
      )
    )

    create(
      index(:okta_directories, [:account_id, :name],
        name: :okta_directories_account_id_name_index,
        unique: true
      )
    )

    execute(
      """
      ALTER TABLE okta_directories
      ADD CONSTRAINT okta_directories_directory_id_fkey
      FOREIGN KEY (account_id, id)
      REFERENCES directories(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE okta_directories
      DROP CONSTRAINT okta_directories_directory_id_fkey
      """
    )
  end
end
