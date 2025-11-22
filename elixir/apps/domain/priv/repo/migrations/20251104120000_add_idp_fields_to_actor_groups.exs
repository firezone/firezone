defmodule Domain.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:directory_id, :binary_id)
      add(:idp_id, :text)
    end

    create(
      index(:actor_groups, [:directory_id],
        name: :actor_groups_directory_id_index,
        where: "directory_id IS NOT NULL"
      )
    )

    execute(
      """
      ALTER TABLE actor_groups
      ADD CONSTRAINT actor_groups_directory_id_fkey
      FOREIGN KEY (account_id, directory_id)
      REFERENCES directories(account_id, id)
      ON DELETE SET NULL
      """,
      """
      ALTER TABLE actor_groups
      DROP CONSTRAINT actor_groups_directory_id_fkey
      """
    )
  end
end
