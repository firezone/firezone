defmodule Portal.Repo.Migrations.RenameProviderIdToAuthProviderIdOnPolicyConditions do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE policies
    SET conditions = (
      SELECT array_agg(
        CASE
          WHEN elem->>'property' = 'provider_id'
          THEN jsonb_set(elem, '{property}', '"auth_provider_id"')
          ELSE elem
        END
      )::jsonb[]
      FROM unnest(policies.conditions) AS elem
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(policies.conditions) AS elem
      WHERE elem->>'property' = 'provider_id'
    )
    """)
  end

  def down do
    execute("""
    UPDATE policies
    SET conditions = (
      SELECT array_agg(
        CASE
          WHEN elem->>'property' = 'auth_provider_id'
          THEN jsonb_set(elem, '{property}', '"provider_id"')
          ELSE elem
        END
      )::jsonb[]
      FROM unnest(policies.conditions) AS elem
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(policies.conditions) AS elem
      WHERE elem->>'property' = 'auth_provider_id'
    )
    """)
  end
end
