defmodule Portal.Repo.Migrations.AddCreatedByDirectoryIdToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:created_by_directory_id, :binary_id)
    end

    create(
      index(:actors, [:account_id, :created_by_directory_id],
        name: :actors_created_by_directory_id_index,
        where: "created_by_directory_id IS NOT NULL"
      )
    )

    execute(
      """
      ALTER TABLE actors
      ADD CONSTRAINT actors_created_by_directory_id_fkey
      FOREIGN KEY (account_id, created_by_directory_id)
      REFERENCES directories(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE actors
      DROP CONSTRAINT actors_created_by_directory_id_fkey
      """
    )
  end
end
