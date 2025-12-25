defmodule Portal.Repo.Migrations.SimplifyAllIndexes do
  use Ecto.Migration

  def up do
    [
      # actors
      "DROP INDEX actors_account_id_index",
      "DROP INDEX actors_created_by_directory_id_index",
      "CREATE INDEX actors_created_by_directory_id_index ON actors (created_by_directory_id) WHERE created_by_directory_id IS NOT NULL",
      "DROP INDEX index_actors_on_account_id_and_type",
      "CREATE INDEX index_actors_on_type ON actors (type)",

      # clients
      "DROP INDEX clients_account_id_index",
      "DROP INDEX clients_account_id_last_seen_at_index",
      "CREATE INDEX clients_last_seen_at_index ON clients (last_seen_at)",

      # external_identities
      "DROP INDEX external_identities_directory_id_index",
      "CREATE INDEX external_identities_directory_id_index ON external_identities (directory_id) WHERE directory_id IS NOT NULL",

      # groups
      "DROP INDEX groups_account_id_id_index",
      "DROP INDEX groups_account_id_index",
      "DROP INDEX groups_directory_id_index",
      "CREATE INDEX groups_directory_id_index ON groups (directory_id) WHERE directory_id IS NOT NULL",

      # memberships
      "DROP INDEX memberships_account_id_group_id_actor_id_index",

      # policies
      "DROP INDEX policies_account_id_resource_id_group_id_index",
      "CREATE INDEX policies_resource_id_index ON policies (resource_id, group_id)",
      "DROP INDEX policies_resource_id_index",

      # policy_authorizations
      "DROP INDEX policy_authorizations_account_id_client_id_index",
      "DROP INDEX policy_authorizations_account_id_gateway_id_index",
      "DROP INDEX policy_authorizations_account_id_policy_id_index",
      "DROP INDEX policy_authorizations_account_id_resource_id_index",
      "DROP INDEX policy_authorizations_account_id_token_id_index",
      "DROP INDEX policy_authorizations_expires_at_account_id_gateway_id_index",
      "CREATE INDEX policy_authorizations_client_id_index ON policy_authorizations (expires_at)",
      "DROP INDEX policy_authorizations_membership_id_idx",
      "CREATE INDEX policy_authorizations_membership_id_index ON policy_authorizations (membership_id) WHERE membership_id IS NOT NULL",
      "DROP INDEX policy_authorizations_membership_id_index",

      # resources
      "DROP INDEX resources_account_id_id_index",
      "DROP INDEX resources_account_id_name_index",
      "CREATE INDEX resources_name_index ON resources (name)",
      "DROP INDEX resources_account_id_site_id_index",
      "CREATE INDEX resources_site_id_index ON resources (site_id) WHERE site_id IS NOT NULL",

      # sites
      "DROP INDEX sites_account_id_id_index",

      # tokens
      "DROP INDEX tokens_account_id_type_index",
      "CREATE INDEX tokens_type_index ON tokens (type)"
    ]
  end

  def down do
    # Irreversible migration
  end
end
