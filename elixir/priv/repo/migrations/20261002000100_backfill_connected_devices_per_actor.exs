defmodule Portal.Repo.Migrations.BackfillConnectedDevicesPerActor do
  use Ecto.Migration

  def up do
    backfill("Starter", 3)
    backfill("Team", 5)
  end

  def down do
    execute("""
    UPDATE accounts
    SET limits = limits - 'connected_devices_per_actor'
    WHERE metadata->'stripe'->>'product_name' IN ('Starter', 'Team')
    """)
  end

  # Stripe product metadata sets this limit on the next subscription event.
  # This only covers the time until then, and never overwrites a value.
  defp backfill(product_name, limit) do
    execute("""
    UPDATE accounts
    SET limits = jsonb_set(limits, '{connected_devices_per_actor}', '#{limit}'::jsonb)
    WHERE metadata->'stripe'->>'product_name' = '#{product_name}'
      AND NOT (limits ? 'connected_devices_per_actor')
    """)
  end
end
