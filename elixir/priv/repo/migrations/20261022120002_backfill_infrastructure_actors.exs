defmodule Portal.Repo.Migrations.BackfillInfrastructureActors do
  @moduledoc """
  Every account gets the system-managed "Infrastructure" service account that
  new accounts are created with. Accounts that already have one are left alone.
  """
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO actors (id, account_id, type, name, managed_by, inserted_at, updated_at)
    SELECT gen_random_uuid(), a.id, 'service_account', 'Infrastructure', 'system', now(), now()
    FROM accounts a
    WHERE NOT EXISTS (
      SELECT 1 FROM actors s
      WHERE s.account_id = a.id AND s.managed_by = 'system' AND s.type = 'service_account'
    )
    """)
  end

  def down do
    execute("""
    DELETE FROM actors
    WHERE managed_by = 'system' AND type = 'service_account' AND name = 'Infrastructure'
    """)
  end
end
