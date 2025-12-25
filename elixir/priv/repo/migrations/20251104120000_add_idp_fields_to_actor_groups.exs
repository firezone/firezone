defmodule Portal.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:directory_id, :binary_id)
      add(:idp_id, :text)
      add(:entity_type, :string, null: false, default: "group")
    end

    create(
      index(:actor_groups, [:account_id, :directory_id],
        name: :actor_groups_directory_id_index,
        where: "directory_id IS NOT NULL"
      )
    )

    create(
      constraint(:actor_groups, :actor_groups_entity_type_must_be_valid,
        check: "entity_type IN ('group', 'org_unit')"
      )
    )

    execute(
      """
      ALTER TABLE actor_groups
      ADD CONSTRAINT actor_groups_directory_id_fkey
      FOREIGN KEY (account_id, directory_id)
      REFERENCES directories(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE actor_groups
      DROP CONSTRAINT actor_groups_directory_id_fkey
      """
    )
  end
end
