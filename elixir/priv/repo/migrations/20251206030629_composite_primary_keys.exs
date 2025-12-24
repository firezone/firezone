defmodule Portal.Repo.Migrations.CompositePrimaryKeys do
  use Ecto.Migration

  def up do
    # Step 1: Drop existing foreign key constraints in order to modify primary keys
    drop_fk_constraints()

    # Step 2: Modify primary keys to be composite keys
    recreate_primary_keys()

    # Step 3: Re-add foreign key constraints to reflect new composite primary keys
    restore_fk_constraints()
  end

  def down do
    # Irreversible migration
  end

  defp drop_fk_constraints do
    [
      "ALTER TABLE clients DROP CONSTRAINT clients_actor_id_fkey",
      "ALTER TABLE clients DROP CONSTRAINT clients_ipv4_fkey",
      "ALTER TABLE clients DROP CONSTRAINT clients_ipv6_fkey",
      "ALTER TABLE external_identities DROP CONSTRAINT external_identities_actor_id_fkey",
      "ALTER TABLE gateways DROP CONSTRAINT gateways_ipv4_fkey",
      "ALTER TABLE gateways DROP CONSTRAINT gateways_ipv6_fkey",
      "ALTER TABLE gateways DROP CONSTRAINT gateways_site_id_fkey",
      "ALTER TABLE memberships DROP CONSTRAINT memberships_actor_id_fkey",
      "ALTER TABLE memberships DROP CONSTRAINT memberships_group_id_fkey",
      "ALTER TABLE policies DROP CONSTRAINT policies_group_id_fkey",
      "ALTER TABLE policies DROP CONSTRAINT policies_resource_id_fkey",
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_client_id_fkey",
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_gateway_id_fkey",
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_membership_id_fkey",
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_policy_id_fkey",
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_resource_id_fkey",
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_token_id_fkey",
      "ALTER TABLE tokens DROP CONSTRAINT tokens_actor_id_fkey",
      "ALTER TABLE tokens DROP CONSTRAINT tokens_site_id_fkey"
    ]
    |> Enum.each(&execute(&1))
  end

  defp recreate_primary_keys do
    # Recreate primary keys over (account_id, id)
    ~w[
      actors
      clients
      external_identities
      gateways
      groups
      memberships
      policies
      policy_authorizations
      resources
      sites
  ]
    |> Enum.each(fn table ->
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_pkey")
      execute("ALTER TABLE #{table} ADD PRIMARY KEY (account_id, id)")
    end)

    # network addresses is special: primary key over (account_id, address)
    execute("ALTER TABLE network_addresses DROP CONSTRAINT network_addresses_pkey")
    execute("ALTER TABLE network_addresses ADD PRIMARY KEY (account_id, address)")

    # we need to skip tokens because its account_id can be null - instead, we'll add a unique index so it can be referenced
    execute("CREATE UNIQUE INDEX tokens_account_id_id_index ON tokens (account_id, id)")
  end

  defp restore_fk_constraints do
    [
      "ALTER TABLE clients ADD CONSTRAINT clients_actor_id_fkey FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE clients ADD CONSTRAINT clients_ipv4_fkey FOREIGN KEY (account_id, ipv4) REFERENCES network_addresses(account_id, address) ON DELETE CASCADE",
      "ALTER TABLE clients ADD CONSTRAINT clients_ipv6_fkey FOREIGN KEY (account_id, ipv6) REFERENCES network_addresses(account_id, address) ON DELETE CASCADE",
      "ALTER TABLE external_identities ADD CONSTRAINT external_identities_actor_id_fkey FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE gateways ADD CONSTRAINT gateways_ipv4_fkey FOREIGN KEY (account_id, ipv4) REFERENCES network_addresses(account_id, address) ON DELETE CASCADE",
      "ALTER TABLE gateways ADD CONSTRAINT gateways_ipv6_fkey FOREIGN KEY (account_id, ipv6) REFERENCES network_addresses(account_id, address) ON DELETE CASCADE",
      "ALTER TABLE gateways ADD CONSTRAINT gateways_site_id_fkey FOREIGN KEY (account_id, site_id) REFERENCES sites(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE memberships ADD CONSTRAINT memberships_actor_id_fkey FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE memberships ADD CONSTRAINT memberships_group_id_fkey FOREIGN KEY (account_id, group_id) REFERENCES groups(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policies ADD CONSTRAINT policies_group_id_fkey FOREIGN KEY (account_id, group_id) REFERENCES groups(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policies ADD CONSTRAINT policies_resource_id_fkey FOREIGN KEY (account_id, resource_id) REFERENCES resources(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policy_authorizations ADD CONSTRAINT policy_authorizations_client_id_fkey FOREIGN KEY (account_id, client_id) REFERENCES clients(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policy_authorizations ADD CONSTRAINT policy_authorizations_gateway_id_fkey FOREIGN KEY (account_id, gateway_id) REFERENCES gateways(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policy_authorizations ADD CONSTRAINT policy_authorizations_membership_id_fkey FOREIGN KEY (account_id, membership_id) REFERENCES memberships(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policy_authorizations ADD CONSTRAINT policy_authorizations_policy_id_fkey FOREIGN KEY (account_id, policy_id) REFERENCES policies(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policy_authorizations ADD CONSTRAINT policy_authorizations_resource_id_fkey FOREIGN KEY (account_id, resource_id) REFERENCES resources(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE policy_authorizations ADD CONSTRAINT policy_authorizations_token_id_fkey FOREIGN KEY (account_id, token_id) REFERENCES tokens(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE tokens ADD CONSTRAINT tokens_actor_id_fkey FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE tokens ADD CONSTRAINT tokens_site_id_fkey FOREIGN KEY (account_id, site_id) REFERENCES sites(account_id, id) ON DELETE CASCADE"
    ]
    |> Enum.each(&execute(&1))
  end
end
