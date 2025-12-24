defmodule Portal.Repo.Migrations.RequireInternetResourceInInternetSite do
  use Ecto.Migration

  def change do
    # Create a function to enforce only 'internet' resources in 'Internet' site
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

        -- Rule 1: Prevent non-'internet' resources in the 'Internet' gateway group
        IF site_name = 'Internet' AND site_managed_by = 'system' AND resource_type != 'internet' THEN
          RAISE EXCEPTION 'Only internet resource type is allowed in the Internet site'
          USING ERRCODE = '23514', CONSTRAINT = 'internet_resource_in_internet_site';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      """
      DROP FUNCTION IF EXISTS enforce_internet_resource_in_internet_gg();
      """
    )

    # Create a trigger to run the check on insert or update
    execute(
      """
      CREATE TRIGGER internet_resource_in_internet_gg
      BEFORE INSERT OR UPDATE OF resource_id, gateway_group_id
      ON resource_connections
      FOR EACH ROW
      EXECUTE FUNCTION enforce_internet_resource_in_internet_gg();
      """,
      """
      DROP TRIGGER IF EXISTS internet_resource_in_internet_gg ON resource_connections;
      """
    )
  end
end
