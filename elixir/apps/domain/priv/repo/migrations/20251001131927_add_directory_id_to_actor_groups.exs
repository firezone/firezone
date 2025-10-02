defmodule Domain.Repo.Migrations.AddDirectoryIdToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:directory_id, :binary_id, null: false)
    end

    create(
      index(:actor_groups, [:account_id, :directory_id, :provider_identifier],
        unique: true,
        where:
          "deleted_at IS NULL AND directory_id IS NOT NULL AND provider_identifier IS NOT NULL"
      )
    )

    up = """
    ALTER TABLE actor_groups
    ADD CONSTRAINT actor_groups_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE actor_groups
    DROP CONSTRAINT actor_groups_account_directory_fk
    """

    execute(up, down)
  end
end
