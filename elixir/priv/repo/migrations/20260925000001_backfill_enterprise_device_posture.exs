defmodule Portal.Repo.Migrations.BackfillEnterpriseDevicePosture do
  use Ecto.Migration

  def up do
    # Match Portal.Billing.plan_type/1, including legacy Enterprise plan names.
    execute("""
    UPDATE accounts
    SET features = COALESCE(features, '{}'::jsonb) || '{"device_posture": true}'::jsonb
    WHERE metadata->'stripe'->>'product_name' LIKE 'Enterprise%'
      AND features->'device_posture' IS DISTINCT FROM 'true'::jsonb
    """)
  end

  # Previous entitlement values cannot be recovered, and rollback must not
  # revoke access granted by Stripe or an administrator after the backfill.
  def down, do: :ok
end
