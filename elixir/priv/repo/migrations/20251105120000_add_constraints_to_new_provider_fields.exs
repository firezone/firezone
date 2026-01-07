defmodule Portal.Repo.Migrations.AddConstraintsToNewProviderFields do
  use Ecto.Migration

  def change do
    # First, some actors that didn't have any identities, won't have emails, so set a dummy email for these
    execute(
      """
      UPDATE actors
      SET email = 'missing-email-' || id || '@firezone.invalid'
      WHERE email IS NULL
        AND type IN ('account_user', 'account_admin_user')
      """,
      ""
    )

    # Not all actors have emails, but account users and account admin users must have one
    create(
      constraint(:actors, :type_is_valid,
        check: """
          (type IN ('account_user', 'account_admin_user') AND email IS NOT NULL)
          OR (type IN ('service_account', 'api_client') AND email IS NULL)
        """
      )
    )

    # Delete any external identities that are missing the new required fields
    execute(
      """
      DELETE FROM external_identities
      WHERE issuer IS NULL OR idp_id IS NULL
      """,
      ""
    )

    # Delete duplicate external identities that would violate the new unique constraint
    execute(
      """
      DELETE FROM external_identities
      WHERE id IN (
        SELECT id FROM (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY account_id, actor_id, issuer, idp_id
                   ORDER BY inserted_at DESC
                 ) as rn
          FROM external_identities
        ) ranked
        WHERE rn > 1
      );
      """,
      ""
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
