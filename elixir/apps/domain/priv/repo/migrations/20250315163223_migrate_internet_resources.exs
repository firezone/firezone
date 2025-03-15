defmodule Domain.Repo.Migrations.MigrateInternetResources do
  use Ecto.Migration

  def change do
    # See 20250224205226_require_internet_resource_in_internet_site for the previous migration.
    # We want to now enforce that only the Internet Resource can be in the Internet Site.

    # Drop existing trigger
    execute(
    """
    DROP TRIGGER IF EXISTS internet_resource_in_internet_gg ON resource_connections;
    """
    )
    execute(
    """
    DROP FUNCTION IF EXISTS enforce_internet_resource_in_internet_gg();
    """
    )

    # Recreate it, except this time enforcing that *both* the following hold true:
    # 1. only internet resources can be the internet site
    # 2. on non-internet resources can be in other sites
    execute(
"""
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
      EXECUTE FUNCTION enforce_internet_resource_in_internet_gg();
""")
  end
end
