defmodule Domain.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:directory, :text)
      add(:idp_id, :text)
    end

    create(
      index(:actor_groups, [:account_id, :directory, :idp_id],
        unique: true,
        name: :actor_groups_account_idp_fields_index,
        where: "directory <> 'firezone'"
      )
    )

    create(
      constraint(
        :actor_groups,
        :directory_must_be_firezone_or_idp_id_present,
        check: """
        (provider_id IS NULL AND provider_identifier IS NULL AND ((directory = 'firezone' AND idp_id IS NULL) OR (directory <> 'firezone' AND idp_id IS NOT NULL)))
        OR (directory IS NULL AND idp_id IS NULL AND provider_id IS NOT NULL AND provider_identifier IS NOT NULL)
        """
      )
    )

    # Drop and recreate the name uniqueness index to include directory
    execute("DROP INDEX IF EXISTS actor_groups_account_id_name_index")

    execute("""
    CREATE UNIQUE INDEX actor_groups_account_id_name_index
    ON actor_groups (account_id, directory, name)
    """)
  end
end
