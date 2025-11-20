defmodule Domain.Repo.Migrations.AddConstraintsToNewProviderFields do
  use Domain, :migration

  def change do
    # Not all actors have emails, but account users and account admin users must have one
    create(
      constraint(:actors, :email_presence_for_user_types,
        check: """
          (type IN ('account_user', 'account_admin_user') AND email IS NOT NULL)
          OR (type NOT IN ('account_user', 'account_admin_user') AND email IS NULL)
        """
      )
    )

    alter table(:auth_identities) do
      modify(:issuer, :text, null: false)
      modify(:idp_id, :text, null: false)
    end

    create(
      index(:auth_identities, [:account_id, :issuer, :idp_id],
        unique: true,
        name: :auth_identities_account_idp_fields_index
      )
    )

    alter table(:actor_groups) do
      modify(:directory, :text, null: false)
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
        check: "directory = 'firezone' AND idp_id IS NULL OR idp_id IS NOT NULL"
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
