defmodule Portal.Repo.Migrations.AddIdpFieldsToExternalIdentities do
  use Ecto.Migration

  def change do
    alter table(:external_identities) do
      add(:issuer, :text)
      add(:directory_id, :binary_id)
      add(:idp_id, :text)
      add(:last_synced_at, :utc_datetime_usec)
      add(:updated_at, :utc_datetime_usec)
    end

    create(
      index(:external_identities, [:account_id, :directory_id],
        name: :external_identities_directory_id_index,
        where: "directory_id IS NOT NULL"
      )
    )

    execute(
      """
      ALTER TABLE external_identities
      ADD CONSTRAINT external_identities_directory_id_fkey
      FOREIGN KEY (account_id, directory_id)
      REFERENCES directories(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE external_identities
      DROP CONSTRAINT external_identities_directory_id_fkey
      """
    )
  end
end
