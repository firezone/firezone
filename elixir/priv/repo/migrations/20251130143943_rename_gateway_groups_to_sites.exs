defmodule Portal.Repo.Migrations.RenameGatewayGroupsToSites do
  use Ecto.Migration

  def change do
    # Rename the gateway_groups table to sites
    rename(table(:gateway_groups), to: table(:sites))

    # Rename group_id to site_id in gateways table
    rename(table(:gateways), :group_id, to: :site_id)

    # Rename gateway_group_id to site_id in tokens table
    rename(table(:tokens), :gateway_group_id, to: :site_id)

    # Rename gateway_group_id to site_id in resource_connections table
    rename(table(:resource_connections), :gateway_group_id, to: :site_id)

    # Rename indexes using ALTER INDEX (only the ones that exist)
    execute(
      "ALTER INDEX gateway_groups_account_id_name_managed_by_index RENAME TO sites_account_id_name_managed_by_index;",
      "ALTER INDEX sites_account_id_name_managed_by_index RENAME TO gateway_groups_account_id_name_managed_by_index;"
    )

    # Rename primary key constraints
    execute(
      "ALTER TABLE sites RENAME CONSTRAINT gateway_groups_pkey TO sites_pkey;",
      "ALTER TABLE sites RENAME CONSTRAINT sites_pkey TO gateway_groups_pkey;"
    )

    # Rename our fk constraints
    execute(
      "ALTER TABLE sites RENAME CONSTRAINT gateway_groups_account_id_fkey TO sites_account_id_fkey;",
      "ALTER TABLE sites RENAME CONSTRAINT sites_account_id_fkey TO gateway_groups_account_id_fkey;"
    )

    execute(
      "ALTER INDEX gateways_account_id_group_id_external_id_index RENAME TO gateways_account_id_site_id_external_id_index;",
      "ALTER INDEX gateways_account_id_site_id_external_id_index RENAME TO gateways_account_id_group_id_external_id_index;"
    )

    execute(
      "ALTER INDEX gateways_group_id_index RENAME TO gateways_site_id_index;",
      "ALTER INDEX gateways_site_id_index RENAME TO gateways_group_id_index;"
    )

    execute(
      "ALTER INDEX tokens_gateway_group_id_index RENAME TO tokens_site_id_index;",
      "ALTER INDEX tokens_site_id_index RENAME TO tokens_gateway_group_id_index;"
    )

    execute(
      "ALTER INDEX resource_connections_gateway_group_id_index RENAME TO resource_connections_site_id_index;",
      "ALTER INDEX resource_connections_site_id_index RENAME TO resource_connections_gateway_group_id_index;"
    )

    # Rename foreign key constraints
    execute(
      "ALTER TABLE gateways RENAME CONSTRAINT gateways_group_id_fkey TO gateways_site_id_fkey;",
      "ALTER TABLE gateways RENAME CONSTRAINT gateways_site_id_fkey TO gateways_group_id_fkey;"
    )

    execute(
      "ALTER TABLE tokens RENAME CONSTRAINT tokens_gateway_group_id_fkey TO tokens_site_id_fkey;",
      "ALTER TABLE tokens RENAME CONSTRAINT tokens_site_id_fkey TO tokens_gateway_group_id_fkey;"
    )

    execute(
      "ALTER TABLE resource_connections RENAME CONSTRAINT resource_connections_gateway_group_id_fkey TO resource_connections_site_id_fkey;",
      "ALTER TABLE resource_connections RENAME CONSTRAINT resource_connections_site_id_fkey TO resource_connections_gateway_group_id_fkey;"
    )

    # Update gateway_groups_count to sites_count in accounts.limits JSON field
    execute(
      """
      UPDATE accounts
      SET limits = jsonb_set(
        limits - 'gateway_groups_count',
        '{sites_count}',
        COALESCE(limits->'gateway_groups_count', 'null'::jsonb)
      )
      WHERE limits ? 'gateway_groups_count';
      """,
      """
      UPDATE accounts
      SET limits = jsonb_set(
        limits - 'sites_count',
        '{gateway_groups_count}',
        COALESCE(limits->'sites_count', 'null'::jsonb)
      )
      WHERE limits ? 'sites_count';
      """
    )

    # Update token types from 'gateway_group' to 'site'
    execute(
      """
      UPDATE tokens
      SET type = 'site'
      WHERE type = 'gateway_group';
      """,
      """
      UPDATE tokens
      SET type = 'gateway_group'
      WHERE type = 'site';
      """
    )

    # First, drop the old trigger that depends on the function
    execute(
      "DROP TRIGGER IF EXISTS internet_resource_in_internet_gg ON resource_connections;",
      "DROP TRIGGER IF EXISTS internet_resource_in_internet_site ON resource_connections;"
    )

    # Now we can drop the old function
    execute(
      "DROP FUNCTION IF EXISTS public.enforce_internet_resource_in_internet_gg();",
      "DROP FUNCTION IF EXISTS public.enforce_internet_resource_in_internet_site();"
    )

    # Create the new function
    execute(
      """
      CREATE OR REPLACE FUNCTION public.enforce_internet_resource_in_internet_site() RETURNS trigger
        LANGUAGE plpgsql
        AS $$
      DECLARE
        resource_type text;
        site_name text;
        site_managed_by text;
      BEGIN
        -- Fetch the resource type and site details
        SELECT r.type INTO resource_type
        FROM resources r
        WHERE r.id = NEW.resource_id;

        SELECT s.name, s.managed_by INTO site_name, site_managed_by
        FROM sites s
        WHERE s.id = NEW.site_id;

        -- Rule: Prevent non-'internet' resources in the 'Internet' site
        IF (site_name = 'Internet' AND site_managed_by = 'system' AND resource_type != 'internet')
        OR (resource_type = 'internet' AND (site_name != 'Internet' OR site_managed_by != 'system')) THEN
          RAISE EXCEPTION 'Only internet resource type is allowed in the Internet site'
          USING ERRCODE = '23514', CONSTRAINT = 'internet_resource_in_internet_site';
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      """
      CREATE OR REPLACE FUNCTION public.enforce_internet_resource_in_internet_gg() RETURNS trigger
        LANGUAGE plpgsql
        AS $$
      DECLARE
        resource_type text;
        site_name text;
        site_managed_by text;
      BEGIN
        -- Fetch the resource type and gateway group details
        SELECT r.type INTO resource_type
        FROM resources r
        WHERE r.id = NEW.resource_id;

        SELECT gg.name, gg.managed_by INTO site_name, site_managed_by
        FROM gateway_groups gg
        WHERE gg.id = NEW.gateway_group_id;

        -- Rule: Prevent non-'internet' resources in the 'Internet' gateway group
        IF (site_name = 'Internet' AND site_managed_by = 'system' AND resource_type != 'internet')
        OR (resource_type = 'internet' AND (site_name != 'Internet' OR site_managed_by != 'system')) THEN
          RAISE EXCEPTION 'Only internet resource type is allowed in the Internet site'
          USING ERRCODE = '23514', CONSTRAINT = 'internet_resource_in_internet_site';
        END IF;

        RETURN NEW;
      END;
      $$;
      """
    )

    # Create the new trigger with the new function
    execute(
      """
      CREATE TRIGGER internet_resource_in_internet_site
      BEFORE INSERT OR UPDATE OF resource_id, site_id ON public.resource_connections
      FOR EACH ROW EXECUTE FUNCTION public.enforce_internet_resource_in_internet_site();
      """,
      """
      CREATE TRIGGER internet_resource_in_internet_gg
      BEFORE INSERT OR UPDATE OF resource_id, gateway_group_id ON public.resource_connections
      FOR EACH ROW EXECUTE FUNCTION public.enforce_internet_resource_in_internet_gg();
      """
    )
  end
end
