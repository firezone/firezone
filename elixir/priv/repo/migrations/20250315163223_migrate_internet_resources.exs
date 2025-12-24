defmodule Portal.Repo.Migrations.MigrateInternetResources do
  use Ecto.Migration

  def change do
    # Step 1
    #
    # Delete all connections where the resource is an internet resource and the gateway group is not the internet site.
    # The Internet resource is / will not be a multi-site resource.
    execute("""
    DELETE FROM resource_connections rc
    WHERE EXISTS (
    SELECT 1 FROM resources r
    WHERE r.id = rc.resource_id AND r.type = 'internet'
    )
    AND NOT EXISTS (
    SELECT 1 FROM gateway_groups gg
    WHERE gg.id = rc.gateway_group_id
    AND gg.name = 'Internet'
    AND gg.managed_by = 'system'
    )
    """)

    # Step 2
    #
    # Insert a connection to the internet site for each internet resource that does not already have one
    execute("""
    INSERT INTO resource_connections (
    resource_id,
    gateway_group_id,
    account_id,
    created_by
    )
    SELECT r.id, gg.id, r.account_id, 'system'
    FROM resources r
    JOIN gateway_groups gg ON r.account_id = gg.account_id
    WHERE r.type = 'internet'
    AND gg.name = 'Internet'
    AND gg.managed_by = 'system'
    AND NOT EXISTS (
    SELECT 1 FROM resource_connections rc
    WHERE rc.resource_id = r.id
    AND rc.gateway_group_id = gg.id
    )
    """)

    # Step 3
    #
    # Recreate existing constraint so that both hold true:
    #   - only internet resources can be in the internet site
    #   - on non-internet resources can be in other sites
    # See 20250224205226_require_internet_resource_in_internet_site for the previous migration.
    # We want to now enforce that only the Internet Resource can be in the Internet Site.

    execute("""
    DROP TRIGGER IF EXISTS internet_resource_in_internet_gg ON resource_connections;
    """)

    execute("""
    DROP FUNCTION IF EXISTS enforce_internet_resource_in_internet_gg();
    """)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_internet_resource_in_internet_gg()
    RETURNS TRIGGER AS $$
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
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER internet_resource_in_internet_gg
    BEFORE INSERT OR UPDATE OF resource_id, gateway_group_id
    ON resource_connections
    FOR EACH ROW
    EXECUTE FUNCTION enforce_internet_resource_in_internet_gg()
    """)
  end
end
