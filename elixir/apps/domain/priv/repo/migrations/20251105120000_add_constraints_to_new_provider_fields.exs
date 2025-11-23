defmodule Domain.Repo.Migrations.AddConstraintsToNewProviderFields do
  use Ecto.Migration

  def change do
    # Not all actors have emails, but account users and account admin users must have one
    create(
      constraint(:actors, :type_is_valid,
        check: """
          (type IN ('account_user', 'account_admin_user') AND email IS NOT NULL)
          OR (type IN ('service_account', 'api_client') AND email IS NULL)
        """
      )
    )

    alter table(:external_identities) do
      modify(:issuer, :text, null: false)
      modify(:idp_id, :text, null: false)
    end

    create(
      index(:external_identities, [:account_id, :idp_id, :issuer],
        unique: true,
        name: :external_identities_account_idp_fields_index
      )
    )

    create(
      index(:actor_groups, [:account_id, :idp_id],
        unique: true,
        name: :actor_groups_account_idp_fields_index,
        where: "idp_id IS NOT NULL"
      )
    )

    execute("DROP INDEX IF EXISTS actor_groups_account_id_name_index")

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS actor_groups_account_id_name_index ON actor_groups(account_id, name) WHERE idp_id IS NULL"
    )
  end
end
