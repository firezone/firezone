defmodule Portal.Repo.Migrations.RenameFlowsToPolicyAuthorizations do
  use Ecto.Migration

  def change do
    # Rename the table
    rename(table(:flows), to: table(:policy_authorizations))

    # Rename indexes
    execute(
      "ALTER INDEX flows_pkey RENAME TO policy_authorizations_pkey",
      "ALTER INDEX policy_authorizations_pkey RENAME TO flows_pkey"
    )

    execute(
      "ALTER INDEX flows_account_id_client_id_index RENAME TO policy_authorizations_account_id_client_id_index",
      "ALTER INDEX policy_authorizations_account_id_client_id_index RENAME TO flows_account_id_client_id_index"
    )

    execute(
      "ALTER INDEX flows_account_id_gateway_id_index RENAME TO policy_authorizations_account_id_gateway_id_index",
      "ALTER INDEX policy_authorizations_account_id_gateway_id_index RENAME TO flows_account_id_gateway_id_index"
    )

    execute(
      "ALTER INDEX flows_account_id_policy_id_index RENAME TO policy_authorizations_account_id_policy_id_index",
      "ALTER INDEX policy_authorizations_account_id_policy_id_index RENAME TO flows_account_id_policy_id_index"
    )

    execute(
      "ALTER INDEX flows_account_id_resource_id_index RENAME TO policy_authorizations_account_id_resource_id_index",
      "ALTER INDEX policy_authorizations_account_id_resource_id_index RENAME TO flows_account_id_resource_id_index"
    )

    execute(
      "ALTER INDEX flows_account_id_token_id_index RENAME TO policy_authorizations_account_id_token_id_index",
      "ALTER INDEX policy_authorizations_account_id_token_id_index RENAME TO flows_account_id_token_id_index"
    )

    execute(
      "ALTER INDEX flows_client_id_index RENAME TO policy_authorizations_client_id_index",
      "ALTER INDEX policy_authorizations_client_id_index RENAME TO flows_client_id_index"
    )

    execute(
      "ALTER INDEX flows_expires_at_account_id_gateway_id_index RENAME TO policy_authorizations_expires_at_account_id_gateway_id_index",
      "ALTER INDEX policy_authorizations_expires_at_account_id_gateway_id_index RENAME TO flows_expires_at_account_id_gateway_id_index"
    )

    execute(
      "ALTER INDEX flows_gateway_id_index RENAME TO policy_authorizations_gateway_id_index",
      "ALTER INDEX policy_authorizations_gateway_id_index RENAME TO flows_gateway_id_index"
    )

    execute(
      "ALTER INDEX flows_membership_id_idx RENAME TO policy_authorizations_membership_id_idx",
      "ALTER INDEX policy_authorizations_membership_id_idx RENAME TO flows_membership_id_idx"
    )

    execute(
      "ALTER INDEX flows_membership_id_index RENAME TO policy_authorizations_membership_id_index",
      "ALTER INDEX policy_authorizations_membership_id_index RENAME TO flows_membership_id_index"
    )

    execute(
      "ALTER INDEX flows_policy_id_index RENAME TO policy_authorizations_policy_id_index",
      "ALTER INDEX policy_authorizations_policy_id_index RENAME TO flows_policy_id_index"
    )

    execute(
      "ALTER INDEX flows_resource_id_index RENAME TO policy_authorizations_resource_id_index",
      "ALTER INDEX policy_authorizations_resource_id_index RENAME TO flows_resource_id_index"
    )

    execute(
      "ALTER INDEX flows_token_id_index RENAME TO policy_authorizations_token_id_index",
      "ALTER INDEX policy_authorizations_token_id_index RENAME TO flows_token_id_index"
    )

    # The foreign key constraints are automatically renamed when the table is renamed
    # But we need to rename them explicitly to follow our naming convention
    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_account_id_fkey TO policy_authorizations_account_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_account_id_fkey TO flows_account_id_fkey
      """
    )

    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_client_id_fkey TO policy_authorizations_client_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_client_id_fkey TO flows_client_id_fkey
      """
    )

    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_gateway_id_fkey TO policy_authorizations_gateway_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_gateway_id_fkey TO flows_gateway_id_fkey
      """
    )

    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_membership_id_fkey TO policy_authorizations_membership_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_membership_id_fkey TO flows_membership_id_fkey
      """
    )

    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_policy_id_fkey TO policy_authorizations_policy_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_policy_id_fkey TO flows_policy_id_fkey
      """
    )

    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_resource_id_fkey TO policy_authorizations_resource_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_resource_id_fkey TO flows_resource_id_fkey
      """
    )

    execute(
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT flows_token_id_fkey TO policy_authorizations_token_id_fkey
      """,
      """
        ALTER TABLE policy_authorizations
        RENAME CONSTRAINT policy_authorizations_token_id_fkey TO flows_token_id_fkey
      """
    )
  end
end
