defmodule Portal.Repo.Migrations.BackfillPaidPlanSlugChanges do
  use Ecto.Migration

  def up do
    # Match Portal.Billing.plan_type/1, including legacy Enterprise plan names.
    execute("""
    UPDATE accounts
    SET features = COALESCE(features, '{}'::jsonb) || '{"slug_changes": true}'::jsonb
    WHERE (metadata->'stripe'->>'product_name' IN ('Team', 'Business')
      OR metadata->'stripe'->>'product_name' LIKE 'Enterprise%')
      AND features->'slug_changes' IS DISTINCT FROM 'true'::jsonb
    """)
  end

  # Rollback must not revoke access granted by Stripe or an administrator after
  # the backfill.
  def down, do: :ok
end
